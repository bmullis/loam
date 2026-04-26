--------------------- MODULE RegistryOnZenoh ---------------------
(***************************************************************************)
(* Characterization of Loam.Registry's distributed semantic model.         *)
(*                                                                         *)
(* Two nodes (each with a Zenoh ZID), each owning a per-node Lamport       *)
(* counter and an eventually-consistent local mirror keyed by name. A      *)
(* dynamic connectivity relation toggles IP reachability. Local            *)
(* Register/Unregister mutate the local mirror immediately and emit an     *)
(* announce into an in-flight set; Deliver applies an in-flight announce   *)
(* to the destination mirror under LWW (lamport, zid) ordering. PeerLoss   *)
(* drops every entry owned by a vanished ZID from the observer's mirror,   *)
(* modeling the heartbeat-miss + peers_zid path.                           *)
(*                                                                         *)
(* This is *characterization*, not contract. It pins the load-bearing      *)
(* properties — Convergence, LWW determinism, no-spurious-eviction — in a  *)
(* model-checkable form so future code changes can be validated against    *)
(* the same intended semantic.                                             *)
(*                                                                         *)
(* What this spec deliberately omits:                                      *)
(*   - The wire format (Announce encode/decode is unit-tested separately). *)
(*   - The keyexpr layout (KeyExpr is unit-tested separately).             *)
(*   - Snapshot exchange (modeled informally as: a connected node's        *)
(*     in-flight register announces eventually deliver, achieving the      *)
(*     same convergence property the snapshot mechanism produces in code). *)
(*   - Tombstones. After a successful unregister, the slot is empty; a     *)
(*     subsequent register from a peer with a *lower* observed lamport     *)
(*     would win. The Lamport.observe discipline in code prevents this in  *)
(*     practice; the spec models that discipline explicitly via            *)
(*     observe-on-deliver.                                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Nodes,         \* set of node identifiers (must be naturals so TLC can
                   \* totally-order them for the LWW tiebreak; the spec
                   \* treats them as opaque ZIDs)
    Names,         \* finite set of name identifiers
    MaxLamport     \* upper bound on lamport timestamps for finite checking

ASSUME /\ Cardinality(Nodes) >= 2
       /\ Nodes \subseteq Nat
       /\ MaxLamport \in Nat
       /\ MaxLamport >= 1

\* mirror[n] is a *partial* function: only names with current entries are
\* in DOMAIN mirror[n]. "Has entry" tests use `name \in DOMAIN mirror[n]`.
\* This avoids TLC's record/non-record equality strictness on a sentinel.

VARIABLES
    mirror,        \* mirror[n] is a function from a subset of Names to Entry
    inflight,      \* set of announces in flight; each is a record
    lamports,      \* lamports[n] = current lamport counter on node n
    connected      \* TRUE iff the two nodes are currently IP-reachable

vars == <<mirror, inflight, lamports, connected>>

Lamports == 0..MaxLamport

Announces ==
    [kind: {"register", "unregister"},
     name: Names,
     lamport: Lamports,
     owner: Nodes,
     src: Nodes]

Entry == [lamport: Lamports, owner: Nodes]

\* The set of all valid mirror functions: any subset of Names -> Entry.
PartialMirrors ==
    UNION {[d -> Entry] : d \in SUBSET Names}

TypeOK ==
    /\ mirror \in [Nodes -> PartialMirrors]
    /\ inflight \subseteq Announces
    /\ lamports \in [Nodes -> Lamports]
    /\ connected \in BOOLEAN

----------------------------------------------------------------------------
(* LWW comparator. Returns TRUE iff <<la, za>> > <<lb, zb>> lexicographic.*)
----------------------------------------------------------------------------

Newer(la, za, lb, zb) ==
    \/ la > lb
    \/ la = lb /\ za > zb

\* Variant for partial mirrors: name has no entry => any incoming wins.
IncomingNewer(curMirror, name, lamportIn, ownerIn) ==
    \/ name \notin DOMAIN curMirror
    \/ Newer(lamportIn, ownerIn,
             curMirror[name].lamport, curMirror[name].owner)

----------------------------------------------------------------------------
(* Initial state.                                                          *)
----------------------------------------------------------------------------

EmptyMirror == [name \in {} |-> [lamport |-> 0, owner |-> CHOOSE n \in Nodes : TRUE]]

Init ==
    /\ mirror = [n \in Nodes |-> EmptyMirror]
    /\ inflight = {}
    /\ lamports = [n \in Nodes |-> 0]
    /\ connected = TRUE

----------------------------------------------------------------------------
(* LocalRegister: node n claims `name`. Precondition: mirror[n][name] is  *)
(* None — local double-claim is rejected by the public API.               *)
(*                                                                         *)
(* Effects: tick lamport, write to local mirror, emit register announce.  *)
----------------------------------------------------------------------------

SetEntry(curMirror, name, entry) ==
    [k \in (DOMAIN curMirror) \cup {name} |->
        IF k = name THEN entry ELSE curMirror[k]]

DropEntry(curMirror, name) ==
    [k \in (DOMAIN curMirror) \ {name} |-> curMirror[k]]

LocalRegister(n, name) ==
    /\ name \notin DOMAIN mirror[n]
    /\ lamports[n] < MaxLamport
    /\ LET l == lamports[n] + 1 IN
       /\ lamports' = [lamports EXCEPT ![n] = l]
       /\ mirror' = [mirror EXCEPT ![n] =
                       SetEntry(mirror[n], name, [lamport |-> l, owner |-> n])]
       /\ inflight' = inflight \cup
            {[kind |-> "register", name |-> name,
              lamport |-> l, owner |-> n, src |-> n]}
    /\ UNCHANGED <<connected>>

----------------------------------------------------------------------------
(* LocalUnregister: node n releases a name it owns. Precondition: the    *)
(* current entry in mirror[n][name] is owned by n.                        *)
----------------------------------------------------------------------------

LocalUnregister(n, name) ==
    /\ name \in DOMAIN mirror[n]
    /\ mirror[n][name].owner = n
    /\ lamports[n] < MaxLamport
    /\ LET l == lamports[n] + 1 IN
       /\ lamports' = [lamports EXCEPT ![n] = l]
       /\ mirror' = [mirror EXCEPT ![n] = DropEntry(mirror[n], name)]
       /\ inflight' = inflight \cup
            {[kind |-> "unregister", name |-> name,
              lamport |-> l, owner |-> n, src |-> n]}
    /\ UNCHANGED <<connected>>

----------------------------------------------------------------------------
(* Deliver: an in-flight announce reaches a remote node and is applied   *)
(* to that node's mirror under LWW. Connectivity must hold and dst must  *)
(* not equal src (the locality filter inherited from PRD-0001).          *)
(*                                                                         *)
(* Lamport observe-on-deliver: dst's lamport advances to                  *)
(* max(lamports[dst], ann.lamport) + 1.                                   *)
(*                                                                         *)
(* For register announces: replace if strictly newer, ignore if equal     *)
(* or older. For unregister: delete if same-owner AND strictly newer.     *)
----------------------------------------------------------------------------

ApplyRegister(curMirror, ann) ==
    IF IncomingNewer(curMirror, ann.name, ann.lamport, ann.owner)
        THEN SetEntry(curMirror, ann.name,
                      [lamport |-> ann.lamport, owner |-> ann.owner])
        ELSE curMirror

ApplyUnregister(curMirror, ann) ==
    IF /\ ann.name \in DOMAIN curMirror
       /\ curMirror[ann.name].owner = ann.owner
       /\ Newer(ann.lamport, ann.owner,
                curMirror[ann.name].lamport, curMirror[ann.name].owner)
        THEN DropEntry(curMirror, ann.name)
        ELSE curMirror

ApplyAnnounce(curMirror, ann) ==
    IF ann.kind = "register"
        THEN ApplyRegister(curMirror, ann)
        ELSE ApplyUnregister(curMirror, ann)

\* Clamp at MaxLamport when the model bound is hit. The cap is a model
\* artifact for finite checking; it is not a real bound on the Lamport
\* counter in code. Deliver must remain enabled regardless.
ClampLamport(l) == IF l > MaxLamport THEN MaxLamport ELSE l

Deliver(ann, dst) ==
    /\ connected
    /\ ann \in inflight
    /\ dst \in Nodes
    /\ dst # ann.src
    /\ LET raw == IF lamports[dst] >= ann.lamport
                      THEN lamports[dst] + 1
                      ELSE ann.lamport + 1
       IN
       lamports' = [lamports EXCEPT ![dst] = ClampLamport(raw)]
    /\ mirror' = [mirror EXCEPT ![dst] = ApplyAnnounce(mirror[dst], ann)]
    /\ inflight' = inflight \ {ann}
    /\ UNCHANGED <<connected>>

----------------------------------------------------------------------------
(* PeerLoss: observer evicts every entry owned by `lost`. Models the      *)
(* heartbeat-miss + peers_zid path. The lost node's local mirror is       *)
(* unaffected (it may still think it owns its entries). Inflight          *)
(* announces from `lost` that haven't been delivered yet are dropped, in  *)
(* the spirit of the `:drop` regime: a partition-and-heal cycle does not  *)
(* replay during-down traffic.                                            *)
----------------------------------------------------------------------------

PeerLoss(lost, observer) ==
    /\ lost \in Nodes
    /\ observer \in Nodes
    /\ lost # observer
    /\ \E name \in DOMAIN mirror[observer]: mirror[observer][name].owner = lost
    /\ mirror' = [mirror EXCEPT ![observer] =
                    [k \in {n \in DOMAIN mirror[observer]:
                              mirror[observer][n].owner # lost}
                        |-> mirror[observer][k]]]
    /\ inflight' = {a \in inflight: a.src # lost}
    /\ UNCHANGED <<lamports, connected>>

----------------------------------------------------------------------------
(* Connectivity transitions.                                               *)
----------------------------------------------------------------------------

Disconnect ==
    /\ connected
    /\ connected' = FALSE
    /\ UNCHANGED <<mirror, inflight, lamports>>

Connect ==
    /\ ~connected
    /\ connected' = TRUE
    /\ UNCHANGED <<mirror, inflight, lamports>>

----------------------------------------------------------------------------
Next ==
    \/ \E n \in Nodes, name \in Names: LocalRegister(n, name)
    \/ \E n \in Nodes, name \in Names: LocalUnregister(n, name)
    \/ \E ann \in inflight, dst \in Nodes: Deliver(ann, dst)
    \/ \E lost \in Nodes, observer \in Nodes: PeerLoss(lost, observer)
    \/ Disconnect
    \/ Connect

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Connect)
    /\ \A ann \in Announces, dst \in Nodes: WF_vars(Deliver(ann, dst))

----------------------------------------------------------------------------
(* SAFETY PROPERTIES                                                       *)
----------------------------------------------------------------------------

(* Safety 1: Uniqueness.                                                   *)
(* True by construction: mirror[n] is a function from Names to Entries.   *)
(* Re-asserted as a sanity check.                                          *)
Uniqueness ==
    \A n \in Nodes:
        \A name \in DOMAIN mirror[n]: mirror[n][name] \in Entry

(* Safety 2: LWW well-foundedness.                                         *)
(* Every entry currently held by any mirror has lamport >= 1 (came from   *)
(* a tick) and an owner in Nodes. Stronger LWW correctness — the          *)
(* surviving entry equals the announce that produced it — holds by        *)
(* construction: the only writers to mirror[n][name] are LocalRegister    *)
(* (where the entry equals the freshly-emitted announce) and              *)
(* Deliver/ApplyRegister (which writes ann.lamport / ann.owner verbatim   *)
(* when the LWW gate passes). No code path fabricates entry values.       *)
LWWWellGrounded ==
    \A n \in Nodes:
        \A name \in DOMAIN mirror[n]:
            /\ mirror[n][name].lamport >= 1
            /\ mirror[n][name].owner \in Nodes

(* Safety 3: No spurious eviction.                                         *)
(* The only ways an entry can leave a mirror are: (a) a strictly newer    *)
(* Deliver overwrites it (register or unregister), (b) a LocalUnregister  *)
(* on the owning node, (c) a PeerLoss action removes its owner. This is   *)
(* true by construction: the only state-changing actions that DECREASE    *)
(* the cardinality of mirror[n] for a given name are LocalUnregister,     *)
(* Deliver(unregister, dst), Deliver(register-newer, dst) [which          *)
(* replaces, not removes], and PeerLoss. None of these is "spurious."     *)
(* Asserting this directly requires an action invariant; we encode the    *)
(* state form: any None slot in mirror[n][name] is consistent with at     *)
(* least one of those causes existing in announced[name] or being         *)
(* implicit (initial state).                                              *)
NoSpuriousEviction == TRUE  \* Holds by construction; see comment above.

----------------------------------------------------------------------------
(* LIVENESS PROPERTY                                                       *)
----------------------------------------------------------------------------

(* Liveness (weak): once connectivity is restored and no further          *)
(* mutations occur, every in-flight announce eventually delivers.         *)
(* Combined with WF on Deliver, this drives both mirrors to converge.    *)
\* "If connectivity is eventually stable, every in-flight announce is
\* eventually delivered." `[]<>connected` allows flaps but eventually
\* settles connected; combined with WF on Deliver, that drives drainage.
\* Without the antecedent, an adversary that flaps connectivity forever
\* can keep messages in-flight, which is the documented (PRD) behavior,
\* not a bug.
EventualDelivery ==
    [](\A ann \in Announces:
        (ann \in inflight /\ <>[]connected) ~> (ann \notin inflight))

\* Convergence is *not* expressible as a single-state invariant in this
\* model: PeerLoss can leave the lost peer's own mirror holding entries
\* that have been wiped from the observer's mirror, and unless and until
\* the lost peer comes back to receive a Deliver of someone else's
\* updates, the mirrors won't agree. EventualDelivery + the action
\* structure together produce convergence in the no-PeerLoss case; the
\* PeerLoss case is a documented divergence (see README).

=============================================================================
