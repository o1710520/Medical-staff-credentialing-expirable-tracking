;; Medical Staff Credentialing Expirable Tracking Contract
;; Monitors license renewals, certification expirations, and credential reappointment deadlines

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-expired (err u104))
(define-constant err-invalid-date (err u105))
(define-constant err-invalid-status (err u106))

;; Credential status types
(define-constant status-active u1)
(define-constant status-expiring-soon u2)
(define-constant status-expired u3)
(define-constant status-renewal-pending u4)
(define-constant status-verified u5)

;; Credential types
(define-constant cred-type-medical-license u1)
(define-constant cred-type-board-certification u2)
(define-constant cred-type-dea-registration u3)
(define-constant cred-type-cds-license u4)
(define-constant cred-type-hospital-privileges u5)

;; Data Variables
(define-data-var credential-nonce uint u0)
(define-data-var provider-nonce uint u0)
(define-data-var renewal-nonce uint u0)
(define-data-var reminder-threshold uint u90) ;; days before expiration to send reminders

;; Data Maps

;; Provider registry
(define-map providers
  { provider-id: uint }
  {
    owner: principal,
    name: (string-ascii 100),
    specialty: (string-ascii 50),
    registration-date: uint,
    active: bool,
    credential-count: uint
  }
)

;; Credential records
(define-map credentials
  { credential-id: uint }
  {
    provider-id: uint,
    credential-type: uint,
    credential-number: (string-ascii 50),
    issuing-authority: (string-ascii 100),
    issue-date: uint,
    expiration-date: uint,
    status: uint,
    last-verified: uint,
    verification-count: uint
  }
)

;; Renewal submissions
(define-map renewals
  { renewal-id: uint }
  {
    credential-id: uint,
    provider-id: uint,
    submission-date: uint,
    new-expiration-date: uint,
    document-hash: (string-ascii 64),
    verified-by: (optional principal),
    verification-date: (optional uint),
    approved: bool
  }
)

;; Reminder history
(define-map reminders
  { credential-id: uint, reminder-date: uint }
  {
    days-until-expiration: uint,
    sent: bool
  }
)

;; Provider lookup by principal
(define-map provider-principals
  { owner: principal }
  { provider-id: uint }
)

;; Compliance status tracking
(define-map compliance-status
  { provider-id: uint }
  {
    total-credentials: uint,
    active-credentials: uint,
    expiring-soon: uint,
    expired-credentials: uint,
    last-compliance-check: uint,
    compliant: bool
  }
)

;; Read-only functions

(define-read-only (get-provider (provider-id uint))
  (map-get? providers { provider-id: provider-id })
)

(define-read-only (get-credential (credential-id uint))
  (map-get? credentials { credential-id: credential-id })
)

(define-read-only (get-renewal (renewal-id uint))
  (map-get? renewals { renewal-id: renewal-id })
)

(define-read-only (get-provider-by-principal (owner principal))
  (match (map-get? provider-principals { owner: owner })
    provider-data (map-get? providers { provider-id: (get provider-id provider-data) })
    none
  )
)

(define-read-only (get-compliance-status (provider-id uint))
  (map-get? compliance-status { provider-id: provider-id })
)

(define-read-only (is-credential-valid (credential-id uint) (current-block-height uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential
      (ok (and 
        (is-eq (get status credential) status-active)
        (> (get expiration-date credential) current-block-height)
      ))
    (err err-not-found)
  )
)

(define-read-only (check-expiration-status (credential-id uint) (current-block-height uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential
      (let
        (
          (expiration (get expiration-date credential))
          (days-remaining (if (> expiration current-block-height) 
                            (- expiration current-block-height) 
                            u0))
        )
        (ok {
          status: (get status credential),
          days-remaining: days-remaining,
          expired: (<= expiration current-block-height)
        })
      )
    (err err-not-found)
  )
)

;; Public functions

;; Register a new provider
(define-public (register-provider (name (string-ascii 100)) (specialty (string-ascii 50)))
  (let
    (
      (new-provider-id (+ (var-get provider-nonce) u1))
      (current-height block-height)
    )
    (asserts! (is-none (map-get? provider-principals { owner: tx-sender })) (err err-already-exists))
    
    (map-set providers
      { provider-id: new-provider-id }
      {
        owner: tx-sender,
        name: name,
        specialty: specialty,
        registration-date: current-height,
        active: true,
        credential-count: u0
      }
    )
    
    (map-set provider-principals
      { owner: tx-sender }
      { provider-id: new-provider-id }
    )
    
    (map-set compliance-status
      { provider-id: new-provider-id }
      {
        total-credentials: u0,
        active-credentials: u0,
        expiring-soon: u0,
        expired-credentials: u0,
        last-compliance-check: current-height,
        compliant: true
      }
    )
    
    (var-set provider-nonce new-provider-id)
    (ok new-provider-id)
  )
)

;; Add a credential for tracking
(define-public (add-credential 
  (provider-id uint)
  (credential-type uint)
  (credential-number (string-ascii 50))
  (issuing-authority (string-ascii 100))
  (issue-date uint)
  (expiration-date uint)
)
  (let
    (
      (new-credential-id (+ (var-get credential-nonce) u1))
      (current-height block-height)
      (provider-data (unwrap! (map-get? providers { provider-id: provider-id }) (err err-not-found)))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (get owner provider-data))) (err err-unauthorized))
    (asserts! (> expiration-date issue-date) (err err-invalid-date))
    
    (map-set credentials
      { credential-id: new-credential-id }
      {
        provider-id: provider-id,
        credential-type: credential-type,
        credential-number: credential-number,
        issuing-authority: issuing-authority,
        issue-date: issue-date,
        expiration-date: expiration-date,
        status: status-active,
        last-verified: current-height,
        verification-count: u1
      }
    )
    
    ;; Update provider credential count
    (map-set providers
      { provider-id: provider-id }
      (merge provider-data { credential-count: (+ (get credential-count provider-data) u1) })
    )
    
    (var-set credential-nonce new-credential-id)
    (ok new-credential-id)
  )
)

;; Update credential expiration date
(define-public (update-expiration (credential-id uint) (new-expiration-date uint))
  (let
    (
      (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) (err err-not-found)))
      (provider-data (unwrap! (map-get? providers { provider-id: (get provider-id credential-data) }) (err err-not-found)))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (get owner provider-data))) (err err-unauthorized))
    (asserts! (> new-expiration-date block-height) (err err-invalid-date))
    
    (map-set credentials
      { credential-id: credential-id }
      (merge credential-data { 
        expiration-date: new-expiration-date,
        status: status-active,
        last-verified: block-height
      })
    )
    (ok true)
  )
)

;; Submit a renewal request
(define-public (submit-renewal 
  (credential-id uint)
  (new-expiration-date uint)
  (document-hash (string-ascii 64))
)
  (let
    (
      (new-renewal-id (+ (var-get renewal-nonce) u1))
      (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) (err err-not-found)))
      (provider-data (unwrap! (map-get? providers { provider-id: (get provider-id credential-data) }) (err err-not-found)))
    )
    (asserts! (is-eq tx-sender (get owner provider-data)) (err err-unauthorized))
    (asserts! (> new-expiration-date (get expiration-date credential-data)) (err err-invalid-date))
    
    (map-set renewals
      { renewal-id: new-renewal-id }
      {
        credential-id: credential-id,
        provider-id: (get provider-id credential-data),
        submission-date: block-height,
        new-expiration-date: new-expiration-date,
        document-hash: document-hash,
        verified-by: none,
        verification-date: none,
        approved: false
      }
    )
    
    ;; Update credential status to renewal pending
    (map-set credentials
      { credential-id: credential-id }
      (merge credential-data { status: status-renewal-pending })
    )
    
    (var-set renewal-nonce new-renewal-id)
    (ok new-renewal-id)
  )
)

;; Verify and approve a renewal
(define-public (verify-renewal (renewal-id uint))
  (let
    (
      (renewal-data (unwrap! (map-get? renewals { renewal-id: renewal-id }) (err err-not-found)))
      (credential-data (unwrap! (map-get? credentials { credential-id: (get credential-id renewal-data) }) (err err-not-found)))
    )
    (asserts! (is-eq tx-sender contract-owner) (err err-owner-only))
    
    ;; Update renewal record
    (map-set renewals
      { renewal-id: renewal-id }
      (merge renewal-data {
        verified-by: (some tx-sender),
        verification-date: (some block-height),
        approved: true
      })
    )
    
    ;; Update credential with new expiration
    (map-set credentials
      { credential-id: (get credential-id renewal-data) }
      (merge credential-data {
        expiration-date: (get new-expiration-date renewal-data),
        status: status-verified,
        last-verified: block-height,
        verification-count: (+ (get verification-count credential-data) u1)
      })
    )
    
    (ok true)
  )
)

;; Update credential status based on expiration
(define-public (update-credential-status (credential-id uint))
  (let
    (
      (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) (err err-not-found)))
      (current-height block-height)
      (expiration (get expiration-date credential-data))
      (days-remaining (if (> expiration current-height) (- expiration current-height) u0))
      (new-status 
        (if (<= expiration current-height)
          status-expired
          (if (<= days-remaining (var-get reminder-threshold))
            status-expiring-soon
            status-active
          )
        )
      )
    )
    (map-set credentials
      { credential-id: credential-id }
      (merge credential-data { status: new-status })
    )
    (ok new-status)
  )
)

;; Check provider compliance
(define-public (check-provider-compliance (provider-id uint))
  (let
    (
      (provider-data (unwrap! (map-get? providers { provider-id: provider-id }) (err err-not-found)))
      (current-compliance (unwrap! (map-get? compliance-status { provider-id: provider-id }) (err err-not-found)))
    )
    ;; In a real implementation, this would iterate through all credentials
    ;; For this contract, we update the compliance check timestamp
    (map-set compliance-status
      { provider-id: provider-id }
      (merge current-compliance {
        last-compliance-check: block-height
      })
    )
    (ok (get compliant current-compliance))
  )
)

;; Generate reminder for expiring credential
(define-public (generate-reminder (credential-id uint))
  (let
    (
      (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) (err err-not-found)))
      (current-height block-height)
      (expiration (get expiration-date credential-data))
      (days-remaining (if (> expiration current-height) (- expiration current-height) u0))
    )
    (asserts! (is-eq tx-sender contract-owner) (err err-owner-only))
    
    (map-set reminders
      { credential-id: credential-id, reminder-date: current-height }
      {
        days-until-expiration: days-remaining,
        sent: true
      }
    )
    (ok true)
  )
)

;; Deactivate a provider
(define-public (deactivate-provider (provider-id uint))
  (let
    (
      (provider-data (unwrap! (map-get? providers { provider-id: provider-id }) (err err-not-found)))
    )
    (asserts! (is-eq tx-sender contract-owner) (err err-owner-only))
    
    (map-set providers
      { provider-id: provider-id }
      (merge provider-data { active: false })
    )
    (ok true)
  )
)

;; Update reminder threshold
(define-public (set-reminder-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) (err err-owner-only))
    (var-set reminder-threshold new-threshold)
    (ok true)
  )
)


;; title: credential-expiration-tracker
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

