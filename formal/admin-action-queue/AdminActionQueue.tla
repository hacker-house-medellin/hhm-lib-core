--------------------- MODULE AdminActionQueue ---------------------
EXTENDS Naturals

CONSTANTS MaxRetryableFailures, MaxLeaseAttempts

ASSUME
    /\ MaxRetryableFailures \in Nat
    /\ MaxRetryableFailures > 0
    /\ MaxLeaseAttempts \in Nat
    /\ MaxLeaseAttempts >= MaxRetryableFailures

VARIABLES
    requestStatus,
    deliveryStatus,
    attempts,
    leaseToken,
    leaseExpired,
    terminalSeen,
    staleCompletions

vars == <<
    requestStatus,
    deliveryStatus,
    attempts,
    leaseToken,
    leaseExpired,
    terminalSeen,
    staleCompletions
>>

RequestStatuses == {"accepted", "running", "succeeded", "failed", "rejected"}
DeliveryStatuses == {"pending", "delivering", "delivered", "failed", "dead_letter"}
TerminalDeliveryStatuses == {"delivered", "dead_letter"}

TypeOK ==
    /\ requestStatus \in RequestStatuses
    /\ deliveryStatus \in DeliveryStatuses
    /\ attempts \in 0..MaxLeaseAttempts
    /\ leaseToken \in 0..MaxLeaseAttempts
    /\ leaseExpired \in BOOLEAN
    /\ terminalSeen \in BOOLEAN
    /\ staleCompletions \in 0..1

LeaseCoherent ==
    /\ ((deliveryStatus = "delivering") = (leaseToken # 0))
    /\ (deliveryStatus = "delivering" =>
           /\ attempts > 0
           /\ leaseToken = attempts)
    /\ (deliveryStatus # "delivering" => ~leaseExpired)

QueueCoherent ==
    CASE deliveryStatus = "pending" ->
            /\ requestStatus = "accepted"
            /\ attempts = 0
      [] deliveryStatus = "failed" ->
            /\ requestStatus = "accepted"
            /\ attempts > 0
      [] deliveryStatus = "delivering" -> requestStatus = "running"
      [] deliveryStatus = "delivered" -> requestStatus \in {"succeeded", "rejected"}
      [] OTHER -> requestStatus = "failed"

TerminalClosure == terminalSeen => deliveryStatus \in TerminalDeliveryStatuses

Init ==
    /\ requestStatus = "accepted"
    /\ deliveryStatus = "pending"
    /\ attempts = 0
    /\ leaseToken = 0
    /\ leaseExpired = FALSE
    /\ terminalSeen = FALSE
    /\ staleCompletions = 0

ClaimReady ==
    /\ deliveryStatus \in {"pending", "failed"}
    /\ attempts < MaxLeaseAttempts
    /\ requestStatus' = "running"
    /\ deliveryStatus' = "delivering"
    /\ attempts' = attempts + 1
    /\ leaseToken' = attempts + 1
    /\ leaseExpired' = FALSE
    /\ UNCHANGED <<terminalSeen, staleCompletions>>

ExpireCurrentLease ==
    /\ deliveryStatus = "delivering"
    /\ ~leaseExpired
    /\ leaseExpired' = TRUE
    /\ UNCHANGED <<
        requestStatus,
        deliveryStatus,
        attempts,
        leaseToken,
        terminalSeen,
        staleCompletions
       >>

ReclaimExpiredLease ==
    /\ deliveryStatus = "delivering"
    /\ leaseExpired
    /\ attempts < MaxLeaseAttempts
    /\ requestStatus' = "running"
    /\ deliveryStatus' = "delivering"
    /\ attempts' = attempts + 1
    /\ leaseToken' = attempts + 1
    /\ leaseExpired' = FALSE
    /\ UNCHANGED <<terminalSeen, staleCompletions>>

ExhaustExpiredLease ==
    /\ deliveryStatus = "delivering"
    /\ leaseExpired
    /\ attempts = MaxLeaseAttempts
    /\ requestStatus' = "failed"
    /\ deliveryStatus' = "dead_letter"
    /\ leaseToken' = 0
    /\ leaseExpired' = FALSE
    /\ terminalSeen' = TRUE
    /\ UNCHANGED <<attempts, staleCompletions>>

CompleteSucceeded ==
    /\ deliveryStatus = "delivering"
    /\ ~leaseExpired
    /\ requestStatus' = "succeeded"
    /\ deliveryStatus' = "delivered"
    /\ leaseToken' = 0
    /\ leaseExpired' = FALSE
    /\ terminalSeen' = TRUE
    /\ UNCHANGED <<attempts, staleCompletions>>

CompleteRejected ==
    /\ deliveryStatus = "delivering"
    /\ ~leaseExpired
    /\ requestStatus' = "rejected"
    /\ deliveryStatus' = "delivered"
    /\ leaseToken' = 0
    /\ leaseExpired' = FALSE
    /\ terminalSeen' = TRUE
    /\ UNCHANGED <<attempts, staleCompletions>>

RetryableFailure ==
    /\ deliveryStatus = "delivering"
    /\ ~leaseExpired
    /\ attempts < MaxRetryableFailures
    /\ requestStatus' = "accepted"
    /\ deliveryStatus' = "failed"
    /\ leaseToken' = 0
    /\ leaseExpired' = FALSE
    /\ UNCHANGED <<attempts, terminalSeen, staleCompletions>>

TerminalRetryableFailure ==
    /\ deliveryStatus = "delivering"
    /\ ~leaseExpired
    /\ attempts >= MaxRetryableFailures
    /\ requestStatus' = "failed"
    /\ deliveryStatus' = "dead_letter"
    /\ leaseToken' = 0
    /\ leaseExpired' = FALSE
    /\ terminalSeen' = TRUE
    /\ UNCHANGED <<attempts, staleCompletions>>

ObserveStaleCompletion(suppliedToken) ==
    /\ deliveryStatus = "delivering"
    /\ suppliedToken \in 0..MaxLeaseAttempts
    /\ suppliedToken # leaseToken
    /\ staleCompletions = 0
    /\ staleCompletions' = 1
    /\ UNCHANGED <<
        requestStatus,
        deliveryStatus,
        attempts,
        leaseToken,
        leaseExpired,
        terminalSeen
       >>

Next ==
    \/ ClaimReady
    \/ ExpireCurrentLease
    \/ ReclaimExpiredLease
    \/ ExhaustExpiredLease
    \/ CompleteSucceeded
    \/ CompleteRejected
    \/ RetryableFailure
    \/ TerminalRetryableFailure
    \/ \E suppliedToken \in 0..MaxLeaseAttempts :
           ObserveStaleCompletion(suppliedToken)

Spec == Init /\ [][Next]_vars

=================================================================
