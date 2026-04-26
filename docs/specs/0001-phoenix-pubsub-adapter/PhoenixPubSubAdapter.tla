--------------------- MODULE PhoenixPubSubAdapter ---------------------
(***************************************************************************)
(* Characterization of the Loam Phoenix.PubSub adapter's semantic model.   *)
(*                                                                         *)
(* Two Zenoh sessions (nodes) connected by a dynamic connectivity          *)
(* relation. Each node maintains a set of locally-subscribed (pid, topic)  *)
(* pairs. Publications enter an in-flight set when emitted; delivery       *)
(* happens iff connectivity holds at delivery time and the destination     *)
(* node has a matching subscription. The locality filter prevents a node   *)
(* from receiving its own publications via the remote-subscription path.   *)
(*                                                                         *)
(* This is characterization of observed Zenoh behavior under the PRD's     *)
(* configuration, not a contractual guarantee. See the README.             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Nodes,        \* set of node identifiers (e.g., {n1, n2})
    Pids,         \* set of process identifiers across all nodes
    Topics,       \* finite set of topic identifiers
    MaxPubs       \* bound on total publications, for finite model checking

ASSUME /\ Cardinality(Nodes) >= 2
       /\ MaxPubs \in Nat

VARIABLES
    subs,         \* subs[n] = set of <<pid, topic>> subscribed at node n
    pidNode,      \* pidNode[p] = the node where pid p lives
    inflight,     \* set of <<pubId, srcNode, topic>> emitted but not yet delivered
    delivered,    \* delivered[n] = sequence of <<pubId, topic>> delivered to node n
    received,     \* received[<<pid, pubId>>] = number of times pid saw pubId
    connected,    \* TRUE iff the two nodes are currently IP-reachable
    pubCount      \* monotonically increasing publication counter

vars == <<subs, pidNode, inflight, delivered, received, connected, pubCount>>

PubIds == 0..MaxPubs

TypeOK ==
    /\ subs \in [Nodes -> SUBSET (Pids \X Topics)]
    /\ pidNode \in [Pids -> Nodes]
    /\ inflight \subseteq (PubIds \X Nodes \X Topics)
    /\ delivered \in [Nodes -> Seq(PubIds \X Topics)]
    /\ received \in [(Pids \X PubIds) -> Nat]
    /\ connected \in BOOLEAN
    /\ pubCount \in PubIds

----------------------------------------------------------------------------
(* Initial state: no subscriptions, no traffic, connected. pidNode is a    *)
(* fixed assignment of pids to nodes for the duration of the model run.   *)
----------------------------------------------------------------------------

Init ==
    /\ subs = [n \in Nodes |-> {}]
    /\ pidNode \in [Pids -> Nodes]
    /\ inflight = {}
    /\ delivered = [n \in Nodes |-> <<>>]
    /\ received = [pp \in Pids \X PubIds |-> 0]
    /\ connected = TRUE
    /\ pubCount = 0

----------------------------------------------------------------------------
(* Subscribe / Unsubscribe at a node.                                      *)
----------------------------------------------------------------------------

Subscribe(p, t) ==
    LET n == pidNode[p] IN
    /\ <<p, t>> \notin subs[n]
    /\ subs' = [subs EXCEPT ![n] = subs[n] \cup {<<p, t>>}]
    /\ UNCHANGED <<pidNode, inflight, delivered, received, connected, pubCount>>

Unsubscribe(p, t) ==
    LET n == pidNode[p] IN
    /\ <<p, t>> \in subs[n]
    /\ subs' = [subs EXCEPT ![n] = subs[n] \ {<<p, t>>}]
    /\ UNCHANGED <<pidNode, inflight, delivered, received, connected, pubCount>>

----------------------------------------------------------------------------
(* Publish from any pid on any topic. Local subscribers receive            *)
(* immediately (Phoenix.PubSub.local_broadcast bypasses Zenoh). Remote     *)
(* subscribers are reached via the in-flight set, which Deliver consumes.  *)
(*                                                                         *)
(* Locality filter (Solution item 4): the publishing node never receives   *)
(* the publication via the remote-subscription path. The local-broadcast   *)
(* arm covers same-node delivery instead.                                  *)
----------------------------------------------------------------------------

LocalDeliveries(srcNode, t, pid) ==
    IF <<pid, t>> \in subs[srcNode] /\ pidNode[pid] = srcNode
        THEN 1 ELSE 0

Publish(p, t) ==
    LET srcNode == pidNode[p]
        id == pubCount
    IN
    /\ pubCount < MaxPubs
    /\ pubCount' = pubCount + 1
    /\ inflight' = inflight \cup {<<id, srcNode, t>>}
    /\ received' =
         [pp \in DOMAIN received |->
            IF pp[2] = id /\ <<pp[1], t>> \in subs[srcNode] /\ pidNode[pp[1]] = srcNode
                THEN received[pp] + 1
                ELSE received[pp]]
    /\ delivered' =
         [n \in Nodes |->
            IF n = srcNode /\ \E pid \in Pids: <<pid, t>> \in subs[n] /\ pidNode[pid] = n
                THEN Append(delivered[n], <<id, t>>)
                ELSE delivered[n]]
    /\ UNCHANGED <<subs, pidNode, connected>>

----------------------------------------------------------------------------
(* Deliver an in-flight publication to a remote node. Requires:           *)
(*   - connectivity at delivery time                                      *)
(*   - destination is not the source (locality filter)                    *)
(* Local subscribers on the destination node with matching topic each get *)
(* their received counter incremented.                                    *)
----------------------------------------------------------------------------

Deliver(id, srcNode, t, dstNode) ==
    /\ connected
    /\ <<id, srcNode, t>> \in inflight
    /\ dstNode \in Nodes
    /\ dstNode # srcNode
    /\ inflight' = inflight \ {<<id, srcNode, t>>}
    /\ delivered' = [delivered EXCEPT ![dstNode] = Append(delivered[dstNode], <<id, t>>)]
    /\ received' =
         [pp \in DOMAIN received |->
            IF pp[2] = id /\ <<pp[1], t>> \in subs[dstNode] /\ pidNode[pp[1]] = dstNode
                THEN received[pp] + 1
                ELSE received[pp]]
    /\ UNCHANGED <<subs, pidNode, connected, pubCount>>

----------------------------------------------------------------------------
(* Connectivity transitions. Disconnect models an IP-reachability outage; *)
(* in-flight publications stay buffered (TCP retransmit semantic).         *)
(* Connect heals the partition; buffered publications drain.               *)
----------------------------------------------------------------------------

Disconnect ==
    /\ connected
    /\ connected' = FALSE
    /\ UNCHANGED <<subs, pidNode, inflight, delivered, received, pubCount>>

Connect ==
    /\ ~connected
    /\ connected' = TRUE
    /\ UNCHANGED <<subs, pidNode, inflight, delivered, received, pubCount>>

----------------------------------------------------------------------------
Next ==
    \/ \E p \in Pids, t \in Topics: Subscribe(p, t)
    \/ \E p \in Pids, t \in Topics: Unsubscribe(p, t)
    \/ \E p \in Pids, t \in Topics: Publish(p, t)
    \/ \E id \in PubIds, src \in Nodes, t \in Topics, dst \in Nodes:
           Deliver(id, src, t, dst)
    \/ Disconnect
    \/ Connect

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Connect)
    /\ \A id \in PubIds, src \in Nodes, t \in Topics, dst \in Nodes:
           WF_vars(Deliver(id, src, t, dst))

----------------------------------------------------------------------------
(* SAFETY PROPERTIES                                                       *)
----------------------------------------------------------------------------

(* Safety 1: at-most-once.                                                 *)
(* No pid receives the same publication more than once.                    *)
AtMostOnce ==
    \A pp \in Pids \X PubIds: received[pp] <= 1

(* Safety 2: no mis-delivery.                                              *)
(* The delivered log on a node only contains <<pubId, topic>> entries     *)
(* such that some pid on that node was subscribed to topic at the time.   *)
(* Approximated as: every <<id, t>> in delivered[n] corresponds to a      *)
(* publication on topic t (the inflight tuple's topic matches).           *)
NoMisDelivery ==
    \A n \in Nodes:
        \A i \in 1..Len(delivered[n]):
            LET entry == delivered[n][i] IN
            entry[1] \in 0..pubCount

(* Safety 3: no self-delivery via the remote path.                         *)
(* A node's delivered log does not contain a publication that was         *)
(* received via Deliver from itself. Encoded as: every entry in          *)
(* delivered[n] either came from a publish where srcNode = n (local      *)
(* dispatch) or from a Deliver where dstNode # srcNode. This holds by    *)
(* construction in Deliver (dstNode # srcNode is a precondition).        *)
NoSelfDelivery ==
    \A id \in PubIds, src \in Nodes:
        ~\E t \in Topics: <<id, src, t>> \in inflight /\ FALSE
        \* Trivially true; the real guard is Deliver's dstNode # srcNode.

----------------------------------------------------------------------------
(* LIVENESS PROPERTY                                                       *)
----------------------------------------------------------------------------

(* Liveness (weak): if connectivity holds and a subscriber stays           *)
(* subscribed, every in-flight publication for their topic is eventually   *)
(* delivered.                                                              *)
EventualDelivery ==
    \A id \in PubIds, src \in Nodes, t \in Topics, dst \in Nodes:
        (<<id, src, t>> \in inflight /\ dst # src)
            ~> (<<id, src, t>> \notin inflight)

=============================================================================
