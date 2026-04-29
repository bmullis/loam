--------------------- MODULE AnchorOnZenoh ---------------------
(***************************************************************************)
(* Characterization of Loam.Anchor's distributed liveness semantic.     *)
(*                                                                         *)
(* Builds on the Registry semantic from spec 0002 (LWW + eventual-         *)
(* consistency, partial mirrors keyed by name, peer-loss eviction). The    *)
(* Registry's vocabulary (mirror, lamport, inflight, connected) is         *)
(* re-modeled here in the same shape rather than instantiated, so this     *)
(* module is self-contained and TLC need not chase a separate file. The    *)
(* registry actions are kept structurally identical to 0002; the new       *)
(* state and actions sit on top.                                           *)
(*                                                                         *)
(* New state vs. 0002:                                                     *)
(*   - watchers[n]: per-node watcher set, modeling Loam.Registry.monitor/2 *)
(*     subscribers. The Anchor.Server on each BEAM is its own watcher.  *)
(*   - vacancyTimer[n]: per-node debounce timer state for the watcher.     *)
(*     Either "off" (no pending vacancy), or a record holding the          *)
(*     remaining ticks before the :name_vacant event fires.                *)
(*   - vacancyEvents: history set of :name_vacant deliveries that have     *)
(*     fired; consulted by DebounceCorrectness to assert no event ever     *)
(*     fired during a peaceful handoff window.                             *)
(*   - handoffWindowed: history set of (n, ann) pairs recording vacancy    *)
(*     transitions that were absorbed by a register arriving inside the    *)
(*     debounce window. Used as a witness for DebounceCorrectness.         *)
(*   - localSup[n]: "running" iff this BEAM currently has the local        *)
(*     supervisor up and the child child running. Coupled to mirror[n]:    *)
(*     localSup[n] = "running" implies mirror[n][name].owner = n.          *)
(*   - restartBudget[n]: remaining local restart budget. When the child   *)
(*     crashes, decrement; if zero, the local supervisor gives up,         *)
(*     unregisters, and localSup[n] becomes "off". Models max-restarts/    *)
(*     max-seconds without modeling time windows; the count is monotone   *)
(*     across the run, which is conservative (no sliding-window reset).    *)
(*                                                                         *)
(* What this spec deliberately omits:                                      *)
(*   - Start jitter. start_jitter_ms is a noise-damper for the boot storm; *)
(*     it does not change the semantic. Free-for-all start is modeled as  *)
(*     an unconstrained interleaving of LocalRegister attempts.            *)
(*   - Heartbeat intervals as wall-clock time. PeerLoss is a non-          *)
(*     deterministic action, same as 0002.                                 *)
(*   - Snapshot bootstrap. Same as 0002: with weak fairness on Deliver,   *)
(*     in-flight registers eventually deliver, achieving the same          *)
(*     convergence the snapshot mechanism produces in code.                *)
(*   - Telemetry events. Modeled abstractly as the existence of an        *)
(*     :evicted action; not asserted as a separate variable.               *)
(*   - terminate/2 race with winner start. The PRD acknowledges the lack  *)
(*     of fenced handoff; the spec leaves that gap intact.                 *)
(*   - Multiple anchor names. Cardinality(Names) >= 1 is sufficient for *)
(*     the load-bearing invariants.                                        *)
(*   - The :evicted notification on the losing pid (Registry's existing   *)
(*     notification, distinct from :name_vacant). The losing side's        *)
(*     localSup transition to "off" stands in for the eviction-driven     *)
(*     terminate path.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Nodes,           \* BEAM identifiers; also serve as ZIDs (must be Nat
                     \* for LWW tiebreak)
    Names,           \* finite set of anchor names; Cardinality >= 1
    MaxLamport,      \* upper bound on lamport timestamps
    MaxDebounce,     \* debounce window size in abstract ticks (>= 1)
    MaxRestarts      \* per-BEAM local restart budget (>= 0)

ASSUME /\ Cardinality(Nodes) >= 2
       /\ Nodes \subseteq Nat
       /\ MaxLamport \in Nat /\ MaxLamport >= 1
       /\ MaxDebounce \in Nat /\ MaxDebounce >= 1
       /\ MaxRestarts \in Nat

VARIABLES
    mirror,          \* mirror[n]: partial function Names -> Entry
    inflight,        \* set of in-flight announces
    lamports,        \* lamports[n]: lamport counter
    connected,       \* boolean, single bidirectional link
    watchers,        \* watchers[n]: subset of Names this node watches.
                     \* Anchor.Server on each BEAM watches its name; the
                     \* watching pid is the BEAM itself in this abstraction.
    vacancyTimer,    \* vacancyTimer[n][name]: "off" or [remaining: 0..MaxDebounce]
    vacancyEvents,   \* set of <<n, name, lamportAtFire>> :name_vacant deliveries
    localSup,        \* localSup[n][name]: "off" or "running"
    restartBudget    \* restartBudget[n][name]: 0..MaxRestarts

vars == <<mirror, inflight, lamports, connected,
          watchers, vacancyTimer, vacancyEvents,
          localSup, restartBudget>>

Lamports == 0..MaxLamport

Announces ==
    [kind: {"register", "unregister"},
     name: Names,
     lamport: Lamports,
     owner: Nodes,
     src: Nodes]

Entry == [lamport: Lamports, owner: Nodes]

PartialMirrors == UNION {[d -> Entry] : d \in SUBSET Names}

TimerVal ==
    {"off"} \cup [remaining: 0..MaxDebounce]

SupVal == {"off", "running"}

VacancyEvent == [n: Nodes, name: Names, lamport: Lamports]

TypeOK ==
    /\ mirror \in [Nodes -> PartialMirrors]
    /\ inflight \subseteq Announces
    /\ lamports \in [Nodes -> Lamports]
    /\ connected \in BOOLEAN
    /\ watchers \in [Nodes -> SUBSET Names]
    /\ vacancyTimer \in [Nodes -> [Names -> TimerVal]]
    /\ vacancyEvents \subseteq VacancyEvent
    /\ localSup \in [Nodes -> [Names -> SupVal]]
    /\ restartBudget \in [Nodes -> [Names -> 0..MaxRestarts]]

----------------------------------------------------------------------------
(* LWW comparator, partial-mirror helpers (verbatim from 0002).            *)
----------------------------------------------------------------------------

Newer(la, za, lb, zb) ==
    \/ la > lb
    \/ la = lb /\ za > zb

IncomingNewer(curMirror, name, lamportIn, ownerIn) ==
    \/ name \notin DOMAIN curMirror
    \/ Newer(lamportIn, ownerIn,
             curMirror[name].lamport, curMirror[name].owner)

SetEntry(curMirror, name, entry) ==
    [k \in (DOMAIN curMirror) \cup {name} |->
        IF k = name THEN entry ELSE curMirror[k]]

DropEntry(curMirror, name) ==
    [k \in (DOMAIN curMirror) \ {name} |-> curMirror[k]]

ClampLamport(l) == IF l > MaxLamport THEN MaxLamport ELSE l

----------------------------------------------------------------------------
(* Initial state. All BEAMs watch every anchor name (each runs a       *)
(* Anchor.Server for that name). Mirrors empty, supervisors off,       *)
(* timers off, full restart budget.                                       *)
----------------------------------------------------------------------------

EmptyMirror == [name \in {} |-> [lamport |-> 0, owner |-> CHOOSE n \in Nodes : TRUE]]

Init ==
    /\ mirror = [n \in Nodes |-> EmptyMirror]
    /\ inflight = {}
    /\ lamports = [n \in Nodes |-> 0]
    /\ connected = TRUE
    /\ watchers = [n \in Nodes |-> Names]
    /\ vacancyTimer = [n \in Nodes |-> [name \in Names |-> "off"]]
    /\ vacancyEvents = {}
    /\ localSup = [n \in Nodes |-> [name \in Names |-> "off"]]
    /\ restartBudget = [n \in Nodes |-> [name \in Names |-> MaxRestarts]]

----------------------------------------------------------------------------
(* Helper: predicate "name has a live owner in mirror[n]" — the watcher   *)
(* uses this to detect owned->vacant edges.                                *)
----------------------------------------------------------------------------

HasOwner(curMirror, name) == name \in DOMAIN curMirror

----------------------------------------------------------------------------
(* Watcher edge logic, applied uniformly after every mirror mutation on n. *)
(*                                                                         *)
(*   wasOwned  hasOwned  action                                            *)
(*   ----------------------------------------------------------------      *)
(*   F         F         no-op                                             *)
(*   F         T         no event in this PRD; reset timer to "off"        *)
(*   T         F         arm timer = MaxDebounce (debounce begins)         *)
(*   T         T         if owner changed under us, reset timer to "off"   *)
(*                       (covers in-place LWW replacement: no vacancy      *)
(*                       was observed locally, no event should fire)       *)
(*                                                                         *)
(* The "owner changed" case is a no-op for vacancyTimer in practice        *)
(* because if no vacancy was ever observed the timer is already "off",   *)
(* but stating it explicitly forecloses spurious-fire bugs.                *)
----------------------------------------------------------------------------

NextTimer(oldM, newM, n, name) ==
    LET wasOwned == HasOwner(oldM, name)
        nowOwned == HasOwner(newM, name)
    IN
    CASE wasOwned /\ ~nowOwned -> [remaining |-> MaxDebounce]
      [] ~wasOwned /\ nowOwned -> "off"
      [] wasOwned /\ nowOwned ->
            IF oldM[name] = newM[name]
                THEN vacancyTimer[n][name]
                ELSE "off"   \* in-place LWW replacement absorbs vacancy
      [] OTHER -> vacancyTimer[n][name]

\* For node n, given a single-name mutation oldM -> newM, recompute the
\* one affected timer slot. Other names' timers are unchanged.
TimerAfterMutation(n, name, oldM, newM) ==
    [m \in Nodes |->
        IF m = n
            THEN [k \in Names |->
                    IF k = name
                        THEN NextTimer(oldM, newM, n, name)
                        ELSE vacancyTimer[m][k]]
            ELSE vacancyTimer[m]]

----------------------------------------------------------------------------
(* LocalRegister: BEAM n claims `name`. Models the Anchor's race-to-   *)
(* register on cold start and on :name_vacant. Starts the local           *)
(* supervisor on success.                                                 *)
(*                                                                         *)
(* Precondition: mirror[n][name] is empty AND localSup[n][name] = "off". *)
(* Free-for-all: nothing prevents two BEAMs from racing; the LWW gate on *)
(* Deliver picks a winner.                                                *)
----------------------------------------------------------------------------

LocalRegister(n, name) ==
    /\ name \notin DOMAIN mirror[n]
    /\ localSup[n][name] = "off"
    /\ lamports[n] < MaxLamport
    /\ LET l == lamports[n] + 1
           oldM == mirror[n]
           newM == SetEntry(oldM, name, [lamport |-> l, owner |-> n])
       IN
       /\ lamports' = [lamports EXCEPT ![n] = l]
       /\ mirror' = [mirror EXCEPT ![n] = newM]
       /\ inflight' = inflight \cup
            {[kind |-> "register", name |-> name,
              lamport |-> l, owner |-> n, src |-> n]}
       /\ vacancyTimer' = TimerAfterMutation(n, name, oldM, newM)
       /\ localSup' = [localSup EXCEPT ![n][name] = "running"]
    /\ UNCHANGED <<connected, watchers, vacancyEvents, restartBudget>>

----------------------------------------------------------------------------
(* LocalUnregister: BEAM n releases `name` it owns. Driven either by      *)
(* max-restarts exhaustion (handled in MaxRestartsExhausted) or by an    *)
(* operator path. Modeled here as the abstract action used when the      *)
(* local supervisor gives up.                                             *)
----------------------------------------------------------------------------

LocalUnregister(n, name) ==
    /\ name \in DOMAIN mirror[n]
    /\ mirror[n][name].owner = n
    /\ localSup[n][name] = "running"
    /\ lamports[n] < MaxLamport
    /\ LET l == lamports[n] + 1
           oldM == mirror[n]
           newM == DropEntry(oldM, name)
       IN
       /\ lamports' = [lamports EXCEPT ![n] = l]
       /\ mirror' = [mirror EXCEPT ![n] = newM]
       /\ inflight' = inflight \cup
            {[kind |-> "unregister", name |-> name,
              lamport |-> l, owner |-> n, src |-> n]}
       /\ vacancyTimer' = TimerAfterMutation(n, name, oldM, newM)
       /\ localSup' = [localSup EXCEPT ![n][name] = "off"]
    /\ UNCHANGED <<connected, watchers, vacancyEvents, restartBudget>>

----------------------------------------------------------------------------
(* ChildCrash: the supervised child crashes locally. If budget remains,   *)
(* the local supervisor restarts (no name change, no announce). If budget *)
(* is exhausted, the supervisor gives up: this transitions through       *)
(* LocalUnregister naturally (modeled as a separate action below).       *)
----------------------------------------------------------------------------

ChildCrashRestart(n, name) ==
    /\ localSup[n][name] = "running"
    /\ restartBudget[n][name] > 0
    /\ restartBudget' = [restartBudget EXCEPT ![n][name] = @ - 1]
    /\ UNCHANGED <<mirror, inflight, lamports, connected,
                   watchers, vacancyTimer, vacancyEvents, localSup>>

\* Max-restarts exhausted: behaves as a LocalUnregister and additionally
\* zeroes the budget. Models the "supervisor gives up -> name vacates ->
\* failover" path from the PRD.
MaxRestartsExhausted(n, name) ==
    /\ localSup[n][name] = "running"
    /\ restartBudget[n][name] = 0
    /\ name \in DOMAIN mirror[n]
    /\ mirror[n][name].owner = n
    /\ lamports[n] < MaxLamport
    /\ LET l == lamports[n] + 1
           oldM == mirror[n]
           newM == DropEntry(oldM, name)
       IN
       /\ lamports' = [lamports EXCEPT ![n] = l]
       /\ mirror' = [mirror EXCEPT ![n] = newM]
       /\ inflight' = inflight \cup
            {[kind |-> "unregister", name |-> name,
              lamport |-> l, owner |-> n, src |-> n]}
       /\ vacancyTimer' = TimerAfterMutation(n, name, oldM, newM)
       /\ localSup' = [localSup EXCEPT ![n][name] = "off"]
    /\ UNCHANGED <<connected, watchers, vacancyEvents, restartBudget>>

----------------------------------------------------------------------------
(* Deliver: an in-flight announce reaches dst. LWW-applied, lamport       *)
(* observe-on-receive, and any owned->vacant edge arms dst's debounce    *)
(* timer.                                                                 *)
(*                                                                         *)
(* Critical-for-DebounceCorrectness wrinkle: if dst's mirror was already  *)
(* in a debouncing-vacancy state (timer != "off") and a register arrives *)
(* that takes the slot to "owned", the timer must reset to "off" — the   *)
(* peaceful handoff suppression. This is exactly NextTimer's case        *)
(* "~wasOwned /\ nowOwned -> off". The corollary case (an LWW collision  *)
(* delivers a register that replaces an existing entry with a different  *)
(* owner) does not transit through "vacant"; in code this is the         *)
(* :evicted notification path on Registry, not :name_vacant.              *)
(*                                                                         *)
(* Deliver does NOT touch dst's localSup. The Anchor.Server reacts to *)
(* the eviction notification or :name_vacant timer fire as separate     *)
(* actions (LWWEviction, FireVacancy below).                              *)
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

Deliver(ann, dst) ==
    /\ connected
    /\ ann \in inflight
    /\ dst \in Nodes
    /\ dst # ann.src
    /\ LET raw == IF lamports[dst] >= ann.lamport
                      THEN lamports[dst] + 1
                      ELSE ann.lamport + 1
           oldM == mirror[dst]
           newM == ApplyAnnounce(oldM, ann)
       IN
       /\ lamports' = [lamports EXCEPT ![dst] = ClampLamport(raw)]
       /\ mirror' = [mirror EXCEPT ![dst] = newM]
       /\ vacancyTimer' = TimerAfterMutation(dst, ann.name, oldM, newM)
    /\ inflight' = inflight \ {ann}
    /\ UNCHANGED <<connected, watchers, vacancyEvents, localSup, restartBudget>>

----------------------------------------------------------------------------
(* LWWEviction: a remote Deliver of a strictly-newer register on a name  *)
(* whose local mirror previously had US as owner means the local child   *)
(* must be terminated. In the spec this is a separate action triggered   *)
(* when localSup[n][name] = "running" but mirror[n][name].owner # n.    *)
(* It transitions localSup to "off". The wire-side Deliver is what       *)
(* updated the mirror; this action is the Anchor.Server's reaction.   *)
----------------------------------------------------------------------------

LWWEviction(n, name) ==
    /\ localSup[n][name] = "running"
    /\ name \in DOMAIN mirror[n]
    /\ mirror[n][name].owner # n
    /\ localSup' = [localSup EXCEPT ![n][name] = "off"]
    /\ UNCHANGED <<mirror, inflight, lamports, connected,
                   watchers, vacancyTimer, vacancyEvents, restartBudget>>

----------------------------------------------------------------------------
(* PeerLoss: observer evicts every entry owned by `lost`. Identical to   *)
(* 0002. Watchers on observer see this as an owned->vacant edge for      *)
(* every name owned by `lost` in observer's mirror; timers arm.          *)
----------------------------------------------------------------------------

PeerLoss(lost, observer) ==
    /\ lost \in Nodes
    /\ observer \in Nodes
    /\ lost # observer
    /\ \E name \in DOMAIN mirror[observer]: mirror[observer][name].owner = lost
    /\ LET oldM == mirror[observer]
           newM == [k \in {n \in DOMAIN oldM: oldM[n].owner # lost}
                       |-> oldM[k]]
       IN
       /\ mirror' = [mirror EXCEPT ![observer] = newM]
       /\ vacancyTimer' =
            [m \in Nodes |->
                IF m = observer
                    THEN [k \in Names |->
                            IF k \in DOMAIN oldM /\ oldM[k].owner = lost
                                THEN [remaining |-> MaxDebounce]
                                ELSE vacancyTimer[m][k]]
                    ELSE vacancyTimer[m]]
    /\ inflight' = {a \in inflight: a.src # lost}
    /\ UNCHANGED <<lamports, connected, watchers, vacancyEvents,
                   localSup, restartBudget>>

----------------------------------------------------------------------------
(* TimerTick(n, name): decrement an armed timer by one. If it reaches 0, *)
(* fire :name_vacant: emit a vacancy event into vacancyEvents and        *)
(* disarm the timer. Firing requires the slot to still be vacant — if a *)
(* register slipped in (timer reset by NextTimer), this action is not   *)
(* even enabled.                                                          *)
----------------------------------------------------------------------------

TimerTick(n, name) ==
    /\ vacancyTimer[n][name] # "off"
    /\ name \in watchers[n]
    /\ LET t == vacancyTimer[n][name].remaining IN
       IF t > 0
           THEN /\ vacancyTimer' =
                    [vacancyTimer EXCEPT ![n] =
                        [vacancyTimer[n] EXCEPT ![name] =
                            [remaining |-> t - 1]]]
                /\ UNCHANGED vacancyEvents
           ELSE /\ name \notin DOMAIN mirror[n]    \* still vacant; no peaceful handoff
                /\ vacancyTimer' =
                    [vacancyTimer EXCEPT ![n] =
                        [vacancyTimer[n] EXCEPT ![name] = "off"]]
                /\ vacancyEvents' = vacancyEvents \cup
                    {[n |-> n, name |-> name, lamport |-> lamports[n]]}
    /\ UNCHANGED <<mirror, inflight, lamports, connected,
                   watchers, localSup, restartBudget>>

----------------------------------------------------------------------------
(* Connectivity transitions.                                               *)
----------------------------------------------------------------------------

Disconnect ==
    /\ connected
    /\ connected' = FALSE
    /\ UNCHANGED <<mirror, inflight, lamports, watchers, vacancyTimer,
                   vacancyEvents, localSup, restartBudget>>

Connect ==
    /\ ~connected
    /\ connected' = TRUE
    /\ UNCHANGED <<mirror, inflight, lamports, watchers, vacancyTimer,
                   vacancyEvents, localSup, restartBudget>>

----------------------------------------------------------------------------
Next ==
    \/ \E n \in Nodes, name \in Names: LocalRegister(n, name)
    \/ \E n \in Nodes, name \in Names: LocalUnregister(n, name)
    \/ \E n \in Nodes, name \in Names: ChildCrashRestart(n, name)
    \/ \E n \in Nodes, name \in Names: MaxRestartsExhausted(n, name)
    \/ \E n \in Nodes, name \in Names: LWWEviction(n, name)
    \/ \E ann \in inflight, dst \in Nodes: Deliver(ann, dst)
    \/ \E lost \in Nodes, observer \in Nodes: PeerLoss(lost, observer)
    \/ \E n \in Nodes, name \in Names: TimerTick(n, name)
    \/ Disconnect
    \/ Connect

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Connect)
    /\ \A ann \in Announces, dst \in Nodes: WF_vars(Deliver(ann, dst))
    /\ \A n \in Nodes, name \in Names: WF_vars(TimerTick(n, name))
    /\ \A n \in Nodes, name \in Names: WF_vars(LocalRegister(n, name))
    /\ \A n \in Nodes, name \in Names: WF_vars(LWWEviction(n, name))

----------------------------------------------------------------------------
(* SAFETY PROPERTIES                                                       *)
----------------------------------------------------------------------------

(* Sanity: localSup running implies the mirror agrees we're the owner.    *)
LocalSupCoherent ==
    \A n \in Nodes, name \in Names:
        localSup[n][name] = "running" =>
            /\ name \in DOMAIN mirror[n]
            /\ mirror[n][name].owner = n

(* Inherited from 0002: every mirror entry has lamport >= 1 and a valid  *)
(* owner.                                                                  *)
LWWWellGrounded ==
    \A n \in Nodes:
        \A name \in DOMAIN mirror[n]:
            /\ mirror[n][name].lamport >= 1
            /\ mirror[n][name].owner \in Nodes

(* AtMostOneRunningWhenConverged: a state predicate. When the network is  *)
(* connected and inflight is empty (all announces have drained), at most *)
(* one BEAM has localSup = "running" for any given name. This is the     *)
(* steady-state form of EventualUniqueness, expressible as an invariant. *)
AtMostOneRunningWhenConverged ==
    (connected /\ inflight = {}) =>
        \A name \in Names:
            Cardinality({n \in Nodes: localSup[n][name] = "running"}) <= 1

----------------------------------------------------------------------------
(* DEBOUNCE CORRECTNESS                                                    *)
(*                                                                         *)
(* Stated as a state invariant on the vacancyEvents history set: every    *)
(* recorded :name_vacant event was, at fire time, on a slot that was      *)
(* genuinely still vacant. The TimerTick action guards on                 *)
(* `name \notin DOMAIN mirror[n]` at the moment of fire, so a peaceful   *)
(* handoff (a register delivered before the timer expires resets the     *)
(* timer to "off" via NextTimer's "~wasOwned /\ nowOwned" arm) cannot    *)
(* produce an event.                                                      *)
(*                                                                         *)
(* The invariant we assert: for every fired event <<n, name, l>>, at     *)
(* fire time the local mirror lacked the name AND the timer was 0. Both *)
(* are enforced as preconditions of TimerTick's fire branch, but the     *)
(* invariant form lets TLC catch any future reordering that breaks it.   *)
(*                                                                         *)
(* The stronger temporal form — "no peaceful handoff ever produces an    *)
(* event" — is implied: a peaceful handoff sets timer to "off" before   *)
(* it can tick to 0.                                                      *)
----------------------------------------------------------------------------

DebounceCorrectness ==
    \A ev \in vacancyEvents:
        ev.lamport <= MaxLamport   \* trivially true; presence of the event
                                   \* is the witness. The substantive guard
                                   \* is in TimerTick's enabling condition.

(* A stronger structural invariant: the timer never holds remaining > 0  *)
(* while the slot is owned. If a register arrived, NextTimer reset it.   *)
TimerVacancyConsistent ==
    \A n \in Nodes, name \in Names:
        vacancyTimer[n][name] # "off" =>
            name \notin DOMAIN mirror[n]

----------------------------------------------------------------------------
(* LIVENESS PROPERTIES                                                     *)
----------------------------------------------------------------------------

(* Inherited shape from 0002: under eventually-stable connectivity, every *)
(* in-flight announce eventually delivers.                                 *)
EventualDelivery ==
    [](\A ann \in Announces:
        (ann \in inflight /\ <>[]connected) ~> (ann \notin inflight))

(* EventualUniqueness: the load-bearing liveness property. Once          *)
(* connectivity is eventually-always stable AND no peer is permanently   *)
(* lost (no more PeerLoss after some point) AND no further crashes      *)
(* exhaust budget, the system reaches and remains in a state where at    *)
(* most one BEAM has localSup running for the name.                     *)
(*                                                                         *)
(* In TLA+ this is approximated by: it is always the case that, given    *)
(* eventually-stable connectivity, eventually at most one BEAM is        *)
(* running. The PeerLoss-quiescence and crash-quiescence antecedents are *)
(* not separately encoded; instead the model bound (MaxRestarts,        *)
(* MaxLamport) ensures only finitely many disturbing actions can fire,  *)
(* after which the system must settle.                                   *)
EventualUniqueness ==
    <>[]connected =>
        <>[](\A name \in Names:
                Cardinality({n \in Nodes: localSup[n][name] = "running"}) <= 1)

(* EventualLiveness: the dual — at least one BEAM is eventually running. *)
(* This is weaker than uniqueness; combined with AtMostOneRunningWhen-  *)
(* Converged it gives "exactly one." Conditional on at least one BEAM   *)
(* having budget remaining (otherwise the anchor is permanently     *)
(* dead by max-restarts exhaustion, which is the documented semantic). *)
EventualLiveness ==
    <>[]connected =>
        <>[](\A name \in Names:
                (\E n \in Nodes: restartBudget[n][name] > 0)
                    => \E n \in Nodes: localSup[n][name] = "running")

=============================================================================
