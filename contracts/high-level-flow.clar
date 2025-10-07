(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-UNAUTHORIZED (err u102))
(define-constant ERR-INVALID-STATE (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-FLOW-COMPLETED (err u105))
(define-constant ERR-INVALID-TRANSITION (err u106))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u107))
(define-constant ERR-DEADLINE-PASSED (err u108))
(define-constant ERR-PREREQUISITE-NOT-MET (err u109))

(define-data-var next-flow-id uint u0)
(define-data-var next-instance-id uint u0)
(define-data-var next-step-id uint u0)
(define-data-var execution-fee uint u10000)
(define-data-var automation-fee uint u5000)

(define-map flow-definitions
    { flow-id: uint }
    {
        creator: principal,
        name: (string-ascii 100),
        description: (string-ascii 500),
        version: uint,
        total-steps: uint,
        is-active: bool,
        created-at: uint,
        execution-count: uint,
        success-rate: uint,
        category: (string-ascii 50)
    }
)

(define-map flow-steps
    { flow-id: uint, step-index: uint }
    {
        step-name: (string-ascii 100),
        step-type: (string-ascii 50),
        required-input: (string-ascii 200),
        expected-output: (string-ascii 200),
        timeout-blocks: uint,
        is-automated: bool,
        prerequisite-steps: (list 10 uint),
        executor-role: (string-ascii 50)
    }
)

(define-map flow-instances
    { instance-id: uint }
    {
        flow-id: uint,
        initiator: principal,
        current-step: uint,
        status: (string-ascii 20),
        started-at: uint,
        updated-at: uint,
        completion-deadline: uint,
        input-data: (string-ascii 1000),
        output-data: (string-ascii 1000),
        execution-path: (list 20 uint)
    }
)

(define-map step-executions
    { instance-id: uint, step-index: uint }
    {
        executor: principal,
        execution-status: (string-ascii 20),
        started-at: uint,
        completed-at: uint,
        input-data: (string-ascii 500),
        output-data: (string-ascii 500),
        execution-time: uint,
        gas-used: uint
    }
)

(define-map flow-permissions
    { flow-id: uint, user: principal }
    {
        can-execute: bool,
        can-monitor: bool,
        can-modify: bool,
        can-admin: bool,
        granted-by: principal,
        granted-at: uint
    }
)

(define-map automation-triggers
    { trigger-id: uint }
    {
        flow-id: uint,
        trigger-type: (string-ascii 50),
        trigger-condition: (string-ascii 200),
        is-active: bool,
        created-by: principal,
        execution-count: uint,
        last-triggered: uint
    }
)

(define-map flow-analytics
    { flow-id: uint }
    {
        total-executions: uint,
        successful-executions: uint,
        failed-executions: uint,
        avg-execution-time: uint,
        total-gas-used: uint,
        last-execution: uint
    }
)

(define-private (get-flow-or-fail (flow-id uint))
    (ok (unwrap! (map-get? flow-definitions { flow-id: flow-id }) ERR-NOT-FOUND))
)

(define-private (get-instance-or-fail (instance-id uint))
    (ok (unwrap! (map-get? flow-instances { instance-id: instance-id }) ERR-NOT-FOUND))
)

(define-private (has-flow-permission (flow-id uint) (user principal) (permission (string-ascii 10)))
    (let ((perms (map-get? flow-permissions { flow-id: flow-id, user: user })))
        (if (is-some perms)
            (let ((permissions (unwrap-panic perms)))
                (if (is-eq permission "execute")
                    (get can-execute permissions)
                    (if (is-eq permission "monitor")
                        (get can-monitor permissions)
                        (if (is-eq permission "modify")
                            (get can-modify permissions)
                            (if (is-eq permission "admin")
                                (get can-admin permissions)
                                false
                            )
                        )
                    )
                )
            )
            false
        )
    )
)

(define-private (validate-step-prerequisites (flow-id uint) (step-index uint) (execution-path (list 20 uint)))
    (let ((step-info (map-get? flow-steps { flow-id: flow-id, step-index: step-index })))
        (if (is-some step-info)
            (let ((prerequisites (get prerequisite-steps (unwrap-panic step-info))))
                (fold check-prerequisite prerequisites true)
            )
            false
        )
    )
)

(define-private (check-prerequisite (prereq-step uint) (acc bool))
    (and acc (> prereq-step u0))
)

(define-private (calculate-execution-fee (flow-id uint) (is-automated bool))
    (if is-automated
        (var-get automation-fee)
        (var-get execution-fee)
    )
)

(define-private (update-flow-analytics (flow-id uint) (success bool) (execution-time uint) (gas-used uint))
    (let ((analytics (default-to
            { total-executions: u0, successful-executions: u0, failed-executions: u0, avg-execution-time: u0, total-gas-used: u0, last-execution: u0 }
            (map-get? flow-analytics { flow-id: flow-id })
        )))
        (map-set flow-analytics
            { flow-id: flow-id }
            (merge analytics {
                total-executions: (+ (get total-executions analytics) u1),
                successful-executions: (if success (+ (get successful-executions analytics) u1) (get successful-executions analytics)),
                failed-executions: (if success (get failed-executions analytics) (+ (get failed-executions analytics) u1)),
                avg-execution-time: (/ (+ (* (get avg-execution-time analytics) (get total-executions analytics)) execution-time) (+ (get total-executions analytics) u1)),
                total-gas-used: (+ (get total-gas-used analytics) gas-used),
                last-execution: stacks-block-height
            })
        )
    )
)

(define-public (create-flow (name (string-ascii 100)) (description (string-ascii 500)) (category (string-ascii 50)))
    (let ((flow-id (var-get next-flow-id)))
        (var-set next-flow-id (+ flow-id u1))
        (map-set flow-definitions
            { flow-id: flow-id }
            {
                creator: tx-sender,
                name: name,
                description: description,
                version: u1,
                total-steps: u0,
                is-active: true,
                created-at: stacks-block-height,
                execution-count: u0,
                success-rate: u0,
                category: category
            }
        )
        (map-set flow-permissions
            { flow-id: flow-id, user: tx-sender }
            {
                can-execute: true,
                can-monitor: true,
                can-modify: true,
                can-admin: true,
                granted-by: tx-sender,
                granted-at: stacks-block-height
            }
        )
        (ok flow-id)
    )
)

(define-public (add-flow-step (flow-id uint) (step-name (string-ascii 100)) (step-type (string-ascii 50)) (required-input (string-ascii 200)) (expected-output (string-ascii 200)) (timeout-blocks uint) (is-automated bool) (executor-role (string-ascii 50)))
    (let ((flow (try! (get-flow-or-fail flow-id))))
        (asserts! (or 
            (is-eq tx-sender (get creator flow))
            (has-flow-permission flow-id tx-sender "modify")
        ) ERR-UNAUTHORIZED)
        (let ((step-index (get total-steps flow)))
            (map-set flow-steps
                { flow-id: flow-id, step-index: step-index }
                {
                    step-name: step-name,
                    step-type: step-type,
                    required-input: required-input,
                    expected-output: expected-output,
                    timeout-blocks: timeout-blocks,
                    is-automated: is-automated,
                    prerequisite-steps: (list),
                    executor-role: executor-role
                }
            )
            (map-set flow-definitions
                { flow-id: flow-id }
                (merge flow { total-steps: (+ step-index u1) })
            )
            (ok step-index)
        )
    )
)

(define-public (initiate-flow (flow-id uint) (input-data (string-ascii 1000)) (completion-deadline uint))
    (let (
        (flow (try! (get-flow-or-fail flow-id)))
        (instance-id (var-get next-instance-id))
        (flow-execution-fee (calculate-execution-fee flow-id false))
    )
        (asserts! (get is-active flow) ERR-INVALID-STATE)
        (asserts! (or 
            (is-eq tx-sender (get creator flow))
            (has-flow-permission flow-id tx-sender "execute")
        ) ERR-UNAUTHORIZED)
        (asserts! (> completion-deadline stacks-block-height) ERR-DEADLINE-PASSED)
        (try! (stx-transfer? flow-execution-fee tx-sender CONTRACT-OWNER))
        (var-set next-instance-id (+ instance-id u1))
        (map-set flow-instances
            { instance-id: instance-id }
            {
                flow-id: flow-id,
                initiator: tx-sender,
                current-step: u0,
                status: "running",
                started-at: stacks-block-height,
                updated-at: stacks-block-height,
                completion-deadline: completion-deadline,
                input-data: input-data,
                output-data: "",
                execution-path: (list u0)
            }
        )
        (map-set flow-definitions
            { flow-id: flow-id }
            (merge flow { execution-count: (+ (get execution-count flow) u1) })
        )
        (ok instance-id)
    )
)

(define-public (execute-step (instance-id uint) (step-index uint) (input-data (string-ascii 500)) (output-data (string-ascii 500)))
    (let (
        (instance (try! (get-instance-or-fail instance-id)))
        (flow (try! (get-flow-or-fail (get flow-id instance))))
    )
        (asserts! (is-eq (get status instance) "running") ERR-INVALID-STATE)
        (asserts! (is-eq step-index (get current-step instance)) ERR-INVALID-TRANSITION)
        (asserts! (< stacks-block-height (get completion-deadline instance)) ERR-DEADLINE-PASSED)
        (asserts! (validate-step-prerequisites (get flow-id instance) step-index (get execution-path instance)) ERR-PREREQUISITE-NOT-MET)
        (map-set step-executions
            { instance-id: instance-id, step-index: step-index }
            {
                executor: tx-sender,
                execution-status: "completed",
                started-at: stacks-block-height,
                completed-at: stacks-block-height,
                input-data: input-data,
                output-data: output-data,
                execution-time: u1,
                gas-used: u1000
            }
        )
        (let ((new-step (+ step-index u1)))
            (if (>= new-step (get total-steps flow))
                (begin
                    (map-set flow-instances
                        { instance-id: instance-id }
                        (merge instance {
                            status: "completed",
                            current-step: new-step,
                            updated-at: stacks-block-height,
                            output-data: output-data,
                            execution-path: (unwrap-panic (as-max-len? (append (get execution-path instance) step-index) u20))
                        })
                    )
                    (update-flow-analytics (get flow-id instance) true u1 u1000)
                    (ok "completed")
                )
                (begin
                    (map-set flow-instances
                        { instance-id: instance-id }
                        (merge instance {
                            current-step: new-step,
                            updated-at: stacks-block-height,
                            execution-path: (unwrap-panic (as-max-len? (append (get execution-path instance) step-index) u20))
                        })
                    )
                    (ok "next-step")
                )
            )
        )
    )
)

(define-public (pause-flow (instance-id uint))
    (let ((instance (try! (get-instance-or-fail instance-id))))
        (asserts! (or 
            (is-eq tx-sender (get initiator instance))
            (has-flow-permission (get flow-id instance) tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status instance) "running") ERR-INVALID-STATE)
        (map-set flow-instances
            { instance-id: instance-id }
            (merge instance { 
                status: "paused",
                updated-at: stacks-block-height
            })
        )
        (ok true)
    )
)

(define-public (resume-flow (instance-id uint))
    (let ((instance (try! (get-instance-or-fail instance-id))))
        (asserts! (or 
            (is-eq tx-sender (get initiator instance))
            (has-flow-permission (get flow-id instance) tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status instance) "paused") ERR-INVALID-STATE)
        (map-set flow-instances
            { instance-id: instance-id }
            (merge instance { 
                status: "running",
                updated-at: stacks-block-height
            })
        )
        (ok true)
    )
)

(define-public (cancel-flow (instance-id uint))
    (let ((instance (try! (get-instance-or-fail instance-id))))
        (asserts! (or 
            (is-eq tx-sender (get initiator instance))
            (has-flow-permission (get flow-id instance) tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (asserts! (not (is-eq (get status instance) "completed")) ERR-FLOW-COMPLETED)
        (map-set flow-instances
            { instance-id: instance-id }
            (merge instance { 
                status: "cancelled",
                updated-at: stacks-block-height
            })
        )
        (update-flow-analytics (get flow-id instance) false u0 u0)
        (ok true)
    )
)

(define-public (grant-flow-permission (flow-id uint) (user principal) (can-execute bool) (can-monitor bool) (can-modify bool) (can-admin bool))
    (let ((flow (try! (get-flow-or-fail flow-id))))
        (asserts! (or 
            (is-eq tx-sender (get creator flow))
            (has-flow-permission flow-id tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (map-set flow-permissions
            { flow-id: flow-id, user: user }
            {
                can-execute: can-execute,
                can-monitor: can-monitor,
                can-modify: can-modify,
                can-admin: can-admin,
                granted-by: tx-sender,
                granted-at: stacks-block-height
            }
        )
        (ok true)
    )
)

(define-public (update-platform-settings (execution-fee-new uint) (automation-fee-new uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set execution-fee execution-fee-new)
        (var-set automation-fee automation-fee-new)
        (ok true)
    )
)

(define-read-only (get-flow (flow-id uint))
    (map-get? flow-definitions { flow-id: flow-id })
)

(define-read-only (get-flow-step (flow-id uint) (step-index uint))
    (map-get? flow-steps { flow-id: flow-id, step-index: step-index })
)

(define-read-only (get-instance (instance-id uint))
    (map-get? flow-instances { instance-id: instance-id })
)

(define-read-only (get-step-execution (instance-id uint) (step-index uint))
    (map-get? step-executions { instance-id: instance-id, step-index: step-index })
)

(define-read-only (get-flow-permissions (flow-id uint) (user principal))
    (map-get? flow-permissions { flow-id: flow-id, user: user })
)

(define-read-only (get-flow-analytics (flow-id uint))
    (map-get? flow-analytics { flow-id: flow-id })
)

(define-read-only (get-platform-stats)
    {
        total-flows: (var-get next-flow-id),
        total-instances: (var-get next-instance-id),
        total-steps: (var-get next-step-id),
        execution-fee: (var-get execution-fee),
        automation-fee: (var-get automation-fee)
    }
)

(define-read-only (can-execute-flow (flow-id uint) (user principal))
    (has-flow-permission flow-id user "execute")
)