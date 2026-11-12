;;; k8s-rollout.el --- Mission control for a simulated Kubernetes rollout -*- lexical-binding: t; -*-

;;; Commentary:

;; A scripted agent rolls the Deployment prod/checkout-api from 2.13.4
;; to 2.14.0 on a simulated cluster and runs the whole thing through
;; one A2UI surface.  There is no cluster and no model: a small
;; simulation plays the deployment and ReplicaSet controllers, the
;; kubelet and a cluster-autoscaler draining a node, and the "agent" is
;; Lisp that speaks only A2UI messages (createSurface, updateComponents,
;; updateDataModel) and reacts to the actions you send back.
;;
;;   (load "/path/to/a2ui.el/examples/k8s-rollout.el")
;;   M-x a2ui-example-k8s-rollout
;;
;; What happens:
;;
;; 1. The agent shows its plan, the manifest diff and two options
;;    (maxSurge, and whether to ask you or roll back on an SLO breach).
;; 2. Start rollout.  Every second the agent updates the ReplicaSets,
;;    the pods (status, readiness, restarts, memory against the limit),
;;    telemetry for the outgoing and incoming pods with sparklines, the
;;    PodDisruptionBudget and the event stream.  RET on a pod describes
;;    it, live.
;; 3. 2.14.0 adds an in-process cache, and its pods climb towards their
;;    512Mi limit and get OOMKilled.  The agent pauses the rollout and
;;    adds a decision card to the surface: accept a patch raising the
;;    limit, resume as is, or roll back.  Meanwhile the PDB blocks the
;;    autoscaler from draining a node, because too few pods are healthy.
;; 4. Whatever you pick, the agent carries it through and summarizes.
;;
;; The surface changes shape as it goes (the decision card, the pod
;; detail, the buttons come and go) by the agent resending only the
;; root's children, as `update_a2ui' lets a real agent do.

;;; Code:

(require 'a2ui)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar a2ui-k8s-tick-seconds 1.0
  "Seconds of wall time per simulated second.")

(defvar a2ui-k8s--defer (lambda (fn) (run-at-time 0 nil fn))
  "How an action's handler is run: later, outside the button press.")

(defconst a2ui-k8s--surface "k8s-rollout")
(defconst a2ui-k8s--nodes '("ip-10-0-1-23" "ip-10-0-2-41" "ip-10-0-3-17" "ip-10-0-4-08"))
(defconst a2ui-k8s--drain-node "ip-10-0-3-17"
  "The node the cluster-autoscaler wants to remove during the rollout.")
(defconst a2ui-k8s--image "registry.internal/checkout-api:")
(defconst a2ui-k8s--history 20
  "Ticks of telemetry the sparklines show.")

;;;; The simulated cluster

(cl-defstruct (a2ui-k8s-rs (:constructor a2ui-k8s--rs) (:copier nil))
  name image limit request (desired 0) revision)

(cl-defstruct (a2ui-k8s-pod (:constructor a2ui-k8s--pod) (:copier nil))
  name rs node (phase "Pending") (timer 1) ready (restarts 0)
  (memory 0) (age 0) (backoff 2) last-reason)

(cl-defstruct (a2ui-k8s-world (:constructor a2ui-k8s--world) (:copier nil))
  (tick 0) (seed 20261111) rses target pods (replicas 6) (surge 1)
  (min-available 5) paused events history spikes
  (drain-next 14) drained (blocked 0))

(defun a2ui-k8s--rand (w)
  "Return the next pseudo-random float in [0, 1) of world W.
The world has its own generator, so every run plays the same way."
  (setf (a2ui-k8s-world-seed w)
        (mod (+ (* (a2ui-k8s-world-seed w) 1103515245) 12345) 2147483648))
  (/ (a2ui-k8s-world-seed w) 2147483648.0))

(defun a2ui-k8s--suffix (w)
  "Return a pod name suffix drawn from world W."
  (let ((chars "bcdfghjklmnpqrstvwxz2456789"))
    (apply #'string (cl-loop repeat 5
                             collect (aref chars (floor (* (a2ui-k8s--rand w) (length chars))))))))

(defun a2ui-k8s--event (w type reason object message)
  "Record an event of TYPE and REASON about OBJECT with MESSAGE in W."
  (push (list (a2ui-k8s-world-tick w) type reason object message)
        (a2ui-k8s-world-events w)))

(defun a2ui-k8s--live (w &optional rs)
  "Return W's pods that are not terminating, only RS's when given."
  (seq-filter (lambda (p) (and (not (equal (a2ui-k8s-pod-phase p) "Terminating"))
                               (or (null rs) (eq (a2ui-k8s-pod-rs p) rs))))
              (a2ui-k8s-world-pods w)))

(defun a2ui-k8s--healthy (w)
  "Return how many of W's pods are ready."
  (seq-count #'a2ui-k8s-pod-ready (a2ui-k8s--live w)))

(defun a2ui-k8s--make-world ()
  "Return a cluster running 2.13.4 on six pods."
  (let* ((w (a2ui-k8s--world))
         (old (a2ui-k8s--rs :name "checkout-api-7d9f8c4b6" :image "2.13.4"
                            :limit 512 :request 384 :desired 6 :revision 7))
         (new (a2ui-k8s--rs :name "checkout-api-5c8b7f9d2" :image "2.14.0"
                            :limit 512 :request 384 :desired 0 :revision 8)))
    (setf (a2ui-k8s-world-rses w) (list old new)
          (a2ui-k8s-world-target w) old)
    (cl-loop for node in (list a2ui-k8s--drain-node "ip-10-0-1-23" "ip-10-0-2-41"
                               "ip-10-0-4-08" "ip-10-0-1-23" "ip-10-0-2-41")
             for days in '(9 9 6 6 3 3)
             do (push (a2ui-k8s--pod :name (concat (a2ui-k8s-rs-name old) "-" (a2ui-k8s--suffix w))
                                     :rs old :node node :phase "Running" :ready t
                                     :memory (+ 290 (* 20 (a2ui-k8s--rand w)))
                                     :age (* days 86400))
                      (a2ui-k8s-world-pods w)))
    (a2ui-k8s--event w "Normal" "ScaleDown" (concat "node/" a2ui-k8s--drain-node)
                     "marked the node as unneeded; cordoned, will drain")
    w))

(defun a2ui-k8s--kubelet (w)
  "Advance every pod of W by one second."
  (dolist (p (a2ui-k8s-world-pods w))
    (let ((rs (a2ui-k8s-pod-rs p))
          (pod (concat "pod/" (a2ui-k8s-pod-name p))))
      (cl-incf (a2ui-k8s-pod-age p))
      (cl-decf (a2ui-k8s-pod-timer p))
      (when (<= (a2ui-k8s-pod-timer p) 0)
        (pcase (a2ui-k8s-pod-phase p)
          ("Pending"
           (setf (a2ui-k8s-pod-phase p) "ContainerCreating" (a2ui-k8s-pod-timer p) 1)
           (a2ui-k8s--event w "Normal" "Scheduled" pod
                            (format "Successfully assigned prod/%s to %s"
                                    (a2ui-k8s-pod-name p) (a2ui-k8s-pod-node p))))
          ("ContainerCreating"
           (setf (a2ui-k8s-pod-phase p) "Running" (a2ui-k8s-pod-timer p) 2
                 (a2ui-k8s-pod-memory p) (+ 150 (* 30 (a2ui-k8s--rand w))))
           (a2ui-k8s--event w "Normal" "Started" pod "Started container checkout-api"))
          ("OOMKilled"
           (setf (a2ui-k8s-pod-phase p) "CrashLoopBackOff"
                 (a2ui-k8s-pod-timer p) (a2ui-k8s-pod-backoff p)
                 (a2ui-k8s-pod-backoff p) (min 16 (* 2 (a2ui-k8s-pod-backoff p))))
           (a2ui-k8s--event w "Warning" "BackOff" pod "Back-off restarting failed container checkout-api"))
          ("CrashLoopBackOff"
           (setf (a2ui-k8s-pod-phase p) "Running" (a2ui-k8s-pod-timer p) 2
                 (a2ui-k8s-pod-memory p) (+ 150 (* 30 (a2ui-k8s--rand w)))))
          ("Running"
           (if (not (a2ui-k8s-pod-ready p))
               (setf (a2ui-k8s-pod-ready p) t)
             ;; Serving traffic.  2.14.0 fills an in-process cache that
             ;; plateaus at 640Mi; 2.13.4 holds steady near 300Mi.
             (setf (a2ui-k8s-pod-memory p)
                   (if (equal (a2ui-k8s-rs-image rs) "2.14.0")
                       (min 640 (+ (a2ui-k8s-pod-memory p) 34 (* 16 (a2ui-k8s--rand w))))
                     (+ 290 (* 20 (a2ui-k8s--rand w)))))
             (when (>= (a2ui-k8s-pod-memory p) (a2ui-k8s-rs-limit rs))
               (setf (a2ui-k8s-pod-phase p) "OOMKilled" (a2ui-k8s-pod-ready p) nil
                     (a2ui-k8s-pod-timer p) 1 (a2ui-k8s-pod-memory p) 0
                     (a2ui-k8s-pod-last-reason p) "OOMKilled")
               (cl-incf (a2ui-k8s-pod-restarts p))
               (push (cons rs 3) (a2ui-k8s-world-spikes w))
               (a2ui-k8s--event w "Warning" "OOMKilled" pod
                                (format "Container checkout-api exceeded its memory limit (%dMi), exit code 137"
                                        (a2ui-k8s-rs-limit rs))))))))))
  (setf (a2ui-k8s-world-pods w)
        (seq-remove (lambda (p) (and (equal (a2ui-k8s-pod-phase p) "Terminating")
                                     (<= (a2ui-k8s-pod-timer p) 0)))
                    (a2ui-k8s-world-pods w))))

(defun a2ui-k8s--scale (w rs desired)
  "Set RS's desired replicas in W to DESIRED, with the event."
  (unless (= desired (a2ui-k8s-rs-desired rs))
    (a2ui-k8s--event w "Normal" "ScalingReplicaSet" "deployment/checkout-api"
                     (format "Scaled %s replica set %s to %d"
                             (if (> desired (a2ui-k8s-rs-desired rs)) "up" "down")
                             (a2ui-k8s-rs-name rs) desired))
    (setf (a2ui-k8s-rs-desired rs) desired)))

(defun a2ui-k8s--deployment-controller (w)
  "Move W's ReplicaSets one step towards the target: RollingUpdate.
maxUnavailable is 0, so an old pod goes only when a ready pod is to
spare, except that old pods which are not ready go at once."
  (let* ((target (a2ui-k8s-world-target w))
         (others (remq target (a2ui-k8s-world-rses w)))
         (replicas (a2ui-k8s-world-replicas w))
         (room (- (+ replicas (a2ui-k8s-world-surge w))
                  (apply #'+ (mapcar #'a2ui-k8s-rs-desired (a2ui-k8s-world-rses w))))))
    (when (and (< (a2ui-k8s-rs-desired target) replicas) (> room 0))
      (a2ui-k8s--scale w target (+ (a2ui-k8s-rs-desired target)
                                   (min room (- replicas (a2ui-k8s-rs-desired target))))))
    (let ((spare (max 0 (- (a2ui-k8s--healthy w) replicas))))
      (dolist (rs others)
        (when (> (a2ui-k8s-rs-desired rs) 0)
          (let* ((unhealthy (seq-count (lambda (p) (not (a2ui-k8s-pod-ready p)))
                                       (a2ui-k8s--live w rs)))
                 (cut (min (a2ui-k8s-rs-desired rs) unhealthy))
                 (more (min (- (a2ui-k8s-rs-desired rs) cut) spare)))
            (setq spare (- spare more))
            (a2ui-k8s--scale w rs (- (a2ui-k8s-rs-desired rs) cut more))))))))

(defun a2ui-k8s--terminate (w pod)
  "Start terminating POD of W."
  (setf (a2ui-k8s-pod-phase pod) "Terminating" (a2ui-k8s-pod-ready pod) nil
        (a2ui-k8s-pod-timer pod) 2)
  (a2ui-k8s--event w "Normal" "Killing" (concat "pod/" (a2ui-k8s-pod-name pod))
                   "Stopping container checkout-api"))

(defun a2ui-k8s--replicaset-controller (w)
  "Create or delete pods so each of W's ReplicaSets has its desired count."
  (dolist (rs (a2ui-k8s-world-rses w))
    (let* ((live (a2ui-k8s--live w rs))
           (n (length live))
           (desired (a2ui-k8s-rs-desired rs)))
      (cond
       ((< n desired)
        (dotimes (_ (- desired n))
          (let* ((nodes (remove a2ui-k8s--drain-node a2ui-k8s--nodes))
                 (node (car (seq-sort-by (lambda (node)
                                           (seq-count (lambda (p) (equal (a2ui-k8s-pod-node p) node))
                                                      (a2ui-k8s--live w)))
                                         #'< nodes)))
                 (pod (a2ui-k8s--pod :name (concat (a2ui-k8s-rs-name rs) "-" (a2ui-k8s--suffix w))
                                     :rs rs :node node)))
            (push pod (a2ui-k8s-world-pods w))
            (a2ui-k8s--event w "Normal" "SuccessfulCreate" (concat "replicaset/" (a2ui-k8s-rs-name rs))
                             (concat "Created pod: " (a2ui-k8s-pod-name pod))))))
       ((> n desired)
        ;; Like the real controller: pods that aren't ready go first,
        ;; then the youngest.
        (dolist (pod (seq-take (seq-sort (lambda (a b)
                                           (if (eq (a2ui-k8s-pod-ready a) (a2ui-k8s-pod-ready b))
                                               (< (a2ui-k8s-pod-age a) (a2ui-k8s-pod-age b))
                                             (not (a2ui-k8s-pod-ready a))))
                                         live)
                               (- n desired)))
          (a2ui-k8s--terminate w pod)))))))

(defun a2ui-k8s--autoscaler (w)
  "Let the cluster-autoscaler try to drain its node, as the PDB allows."
  (let ((next (a2ui-k8s-world-drain-next w))
        (node (concat "node/" a2ui-k8s--drain-node)))
    (when (and next (>= (a2ui-k8s-world-tick w) next))
      (let ((pod (seq-find (lambda (p) (equal (a2ui-k8s-pod-node p) a2ui-k8s--drain-node))
                           (a2ui-k8s--live w)))
            (allowed (- (a2ui-k8s--healthy w) (a2ui-k8s-world-min-available w))))
        (cond
         ((null pod)
          (unless (seq-find (lambda (p) (equal (a2ui-k8s-pod-node p) a2ui-k8s--drain-node))
                            (a2ui-k8s-world-pods w))
            (setf (a2ui-k8s-world-drained w) t (a2ui-k8s-world-drain-next w) nil)
            (a2ui-k8s--event w "Normal" "ScaleDown" node "node removed by cluster-autoscaler")))
         ((and (> allowed 0) (a2ui-k8s-pod-ready pod)
               ;; Wait out the rollout's own surge before evicting.
               (>= (a2ui-k8s--healthy w) (a2ui-k8s-world-replicas w)))
          (a2ui-k8s--event w "Normal" "Evicted" (concat "pod/" (a2ui-k8s-pod-name pod))
                           "evicted by cluster-autoscaler to drain the node")
          (a2ui-k8s--terminate w pod)
          (setf (a2ui-k8s-world-drain-next w) (+ (a2ui-k8s-world-tick w) 3)))
         (t
          (when (<= allowed 0)
            (cl-incf (a2ui-k8s-world-blocked w))
            (a2ui-k8s--event w "Warning" "ScaleDownFailed" node
                             (format "failed to evict pod %s: Cannot evict pod as it would violate the pod's disruption budget"
                                     (a2ui-k8s-pod-name pod))))
          (setf (a2ui-k8s-world-drain-next w) (+ (a2ui-k8s-world-tick w) 4))))))))

(defun a2ui-k8s--pressured-p (pod)
  "Return non-nil when POD is serving above 88% of its memory limit."
  (and (a2ui-k8s-pod-ready pod)
       (> (a2ui-k8s-pod-memory pod) (* 0.88 (a2ui-k8s-rs-limit (a2ui-k8s-pod-rs pod))))))

(defun a2ui-k8s--side (w pods rps-per-pod spikes)
  "Return telemetry for the ready PODS of W, or nil when there are none.
Each pod serves RPS-PER-POD.  SPIKES are the error spikes (RS . TICKS)
from recent OOMKills on this side."
  (when pods
    (let* ((n (length pods))
           (errs (mapcar (lambda (p)
                           (+ (if (equal (a2ui-k8s-rs-image (a2ui-k8s-pod-rs p)) "2.14.0") 0.22 0.14)
                              (* 0.06 (a2ui-k8s--rand w))
                              (if (a2ui-k8s--pressured-p p) 1.3 0)))
                         pods))
           (spike (apply #'+ (mapcar (lambda (s) (/ (cdr s) 3.0)) spikes)))
           (p99s (mapcar (lambda (p)
                           (+ (if (equal (a2ui-k8s-rs-image (a2ui-k8s-pod-rs p)) "2.14.0") 126 182)
                              (* 12 (a2ui-k8s--rand w))
                              (if (a2ui-k8s--pressured-p p) 520 0)))
                         pods)))
      (list :n n
            :rps (* n rps-per-pod)
            :err (+ (/ (apply #'+ errs) n) (/ (* 4.5 spike) n))
            :p99 (+ (apply #'max p99s) (* 300 spike))
            :mem (/ (apply #'+ (mapcar #'a2ui-k8s-pod-memory pods)) n)))))

(defun a2ui-k8s--metrics (w)
  "Sample W's telemetry for this second into its history."
  (let* ((target (a2ui-k8s-world-target w))
         (ready (seq-filter #'a2ui-k8s-pod-ready (a2ui-k8s--live w)))
         (rps (+ 1180 (* 60 (sin (/ (a2ui-k8s-world-tick w) 5.0))) (* 20 (a2ui-k8s--rand w))))
         (per (/ rps (max 1 (length ready))))
         (spikes (a2ui-k8s-world-spikes w)))
    (push (list :rps rps
                :in (a2ui-k8s--side w (seq-filter (lambda (p) (eq (a2ui-k8s-pod-rs p) target)) ready)
                                    per (seq-filter (lambda (s) (eq (car s) target)) spikes))
                :out (a2ui-k8s--side w (seq-remove (lambda (p) (eq (a2ui-k8s-pod-rs p) target)) ready)
                                     per (seq-remove (lambda (s) (eq (car s) target)) spikes)))
          (a2ui-k8s-world-history w))
    (setf (a2ui-k8s-world-history w) (seq-take (a2ui-k8s-world-history w) 60)
          (a2ui-k8s-world-spikes w)
          (seq-filter (lambda (s) (> (cdr s) 0))
                      (mapcar (lambda (s) (cons (car s) (1- (cdr s)))) spikes)))))

(defun a2ui-k8s--step (w)
  "Advance world W by one second."
  (cl-incf (a2ui-k8s-world-tick w))
  (a2ui-k8s--kubelet w)
  (unless (a2ui-k8s-world-paused w)
    (a2ui-k8s--deployment-controller w))
  (a2ui-k8s--replicaset-controller w)
  (a2ui-k8s--autoscaler w)
  (a2ui-k8s--metrics w))

(defun a2ui-k8s--complete-p (w)
  "Return non-nil when every pod of W is a ready pod of the target."
  (let ((target (a2ui-k8s-world-target w)))
    (and (= (a2ui-k8s-rs-desired target) (a2ui-k8s-world-replicas w))
         (seq-every-p (lambda (p) (and (eq (a2ui-k8s-pod-rs p) target) (a2ui-k8s-pod-ready p)))
                      (a2ui-k8s-world-pods w))
         (= (length (a2ui-k8s-world-pods w)) (a2ui-k8s-world-replicas w)))))

;;;; Formatting

(defun a2ui-k8s--age (seconds)
  "Return SECONDS as kubectl shows an age."
  (cond ((< seconds 120) (format "%ds" seconds))
        ((< seconds 7200) (format "%dm" (/ seconds 60)))
        ((< seconds 172800) (format "%dh" (/ seconds 3600)))
        (t (format "%dd" (/ seconds 86400)))))

(defun a2ui-k8s--bar (value max width)
  "Return a WIDTH-cell bar filled to VALUE of MAX."
  (let ((n (min width (max 0 (round (* width (/ (float value) (max 1 max))))))))
    (concat (make-string n ?█) (make-string (- width n) ?░))))

(defun a2ui-k8s--spark (values hi)
  "Return a sparkline of VALUES, oldest first, scaled to HI; nil is a gap."
  (let ((bars "▁▂▃▄▅▆▇█"))
    (mapconcat (lambda (v)
                 (if v
                     (string (aref bars (max 0 (min 7 (floor (* 8 (/ (float v) hi)))))))
                   " "))
               values "")))

(defun a2ui-k8s--series (w side key)
  "Return the last `a2ui-k8s--history' values of KEY on SIDE in W, oldest first."
  (let ((values (mapcar (lambda (h) (plist-get (plist-get h side) key))
                        (seq-take (a2ui-k8s-world-history w) a2ui-k8s--history))))
    (append (make-list (- a2ui-k8s--history (length values)) nil) (nreverse values))))

(defun a2ui-k8s--best (w side)
  "Return the best p99 on SIDE of W in the recent history, formatted."
  (if-let* ((values (delq nil (a2ui-k8s--series w side :p99))))
      (format "%.0f ms" (apply #'min values))
    "—"))

;;;; The agent

(cl-defstruct (a2ui-k8s-run (:constructor a2ui-k8s--run) (:copier nil))
  session world (phase 'plan) timer (ask t) steps root
  original (tolerated 0) resumed rolled-back fixed hide-fix
  verify-left detail-pod pause-reason)

(defvar a2ui-k8s--current nil
  "The rollout on screen.")

(defun a2ui-k8s--send (run type body)
  "Send RUN's surface a message of TYPE with BODY."
  (puthash "surfaceId" a2ui-k8s--surface body)
  (a2ui-apply-message (a2ui-k8s-run-session run) (a2ui-obj "version" "v0.9" type body)))

(defun a2ui-k8s--data (run path value)
  "Set PATH of RUN's data model to VALUE."
  (a2ui-k8s--send run "updateDataModel" (a2ui-obj "path" path "value" value)))

(defun a2ui-k8s--p (path)
  "Return a binding to PATH."
  (a2ui-obj "path" path))

(defun a2ui-k8s--c (id type &rest props)
  "Return component ID of TYPE with PROPS."
  (apply #'a2ui-obj "id" id "component" type props))

(defun a2ui-k8s--button (id label action &optional variant context)
  "Return Button ID labelled LABEL sending ACTION, and its label.
VARIANT is its variant; CONTEXT its action context."
  (list (a2ui-k8s--c (concat id "_label") "Text" "text" label)
        (a2ui-k8s--c id "Button" "child" (concat id "_label") "variant" (or variant "default")
                     "action" (a2ui-obj "event" (a2ui-obj "name" action
                                                          "context" (or context (a2ui-obj)))))))

(defun a2ui-k8s--table (id rows columns &rest props)
  "Return Table ID over data ROWS with COLUMNS, (LABEL KEY [ALIGN])..., and PROPS."
  (apply #'a2ui-k8s--c id "Table" "rows" (a2ui-k8s--p rows)
         "columns" (vconcat (mapcar (pcase-lambda (`(,label ,key ,align))
                                      (a2ui-obj "label" label "key" key "align" (or align "left")))
                                    columns))
         props))

(defun a2ui-k8s--section (id title child &optional collapsed)
  "Return Section ID titled TITLE around CHILD, COLLAPSED or not."
  (a2ui-k8s--c id "Section" "title" title "child" child "collapsed" (a2ui-bool collapsed)))

(defun a2ui-k8s--components ()
  "Return every component the surface ever shows."
  (append
   (list
    (a2ui-k8s--c "root" "Column" "children" ["title"])
    (a2ui-k8s--c "title" "Text" "variant" "h2" "text" "Rollout: prod/checkout-api 2.13.4 → 2.14.0")
    (a2ui-k8s--c "subtitle" "Text" "variant" "caption"
                 "text" "Deployment · 6 replicas · RollingUpdate, maxUnavailable 0 · PDB checkout-api-pdb minAvailable 5")
    (a2ui-k8s--c "status" "Text" "text" (a2ui-k8s--p "/live/status"))
    (a2ui-k8s--c "progress" "Text" "variant" "caption" "text" (a2ui-k8s--p "/live/progress"))
    (a2ui-k8s--c "note" "OrgText" "text" (a2ui-k8s--p "/note"))
    (a2ui-k8s--section "plan_sec" "Plan" "plan_table")
    (a2ui-k8s--table "plan_table" "/plan" '(("" "status") ("Step" "step") ("Detail" "detail")))
    (a2ui-k8s--section "change_sec" "Change" "manifest_diff")
    (a2ui-k8s--c "manifest_diff" "Diff" "file" "k8s/checkout-api/deployment.yaml"
                 "diff" (a2ui-k8s--p "/manifest"))
    (a2ui-k8s--section "options_sec" "Options" "options_col")
    (a2ui-k8s--c "options_col" "Column" "children" ["surge" "ask"])
    (a2ui-k8s--c "surge" "Slider" "label" "maxSurge" "min" 1 "max" 3 "value" (a2ui-k8s--p "/options/surge"))
    (a2ui-k8s--c "ask" "CheckBox" "value" (a2ui-k8s--p "/options/ask")
                 "label" "If incoming pods breach their SLOs, pause and ask me (otherwise roll back)")
    (a2ui-k8s--c "plan_buttons" "Row" "children" ["start" "cancel"])
    (a2ui-k8s--section "rs_sec" "ReplicaSets" "rs_table")
    (a2ui-k8s--table "rs_table" "/live/rses"
                     '(("ReplicaSet" "name") ("Rev" "rev" "right") ("Image" "image") ("Mem limit" "limit")
                       ("Desired" "desired" "right") ("Current" "current" "right")
                       ("Ready" "ready" "right") ("Role" "role")))
    (a2ui-k8s--section "pods_sec" "Pods (RET on a pod describes it)" "pods_table")
    (a2ui-k8s--table "pods_table" "/live/pods"
                     '(("Pod" "pod") ("Rev" "rev" "right") ("Status" "status") ("Ready" "ready")
                       ("Restarts" "restarts" "right") ("Memory" "memory") ("Node" "node")
                       ("Age" "age" "right"))
                     "rowKey" "pod"
                     "rowAction" (a2ui-obj "event" (a2ui-obj "name" "describe_pod"
                                                             "context" (a2ui-obj "pod" (a2ui-k8s--p "pod")))))
    (a2ui-k8s--section "detail_sec" (a2ui-k8s--p "/detail/title") "detail_col")
    (a2ui-k8s--c "detail_col" "Column" "children" ["detail_code" "hide_detail"])
    (a2ui-k8s--c "detail_code" "Code" "text" (a2ui-k8s--p "/detail/text"))
    (a2ui-k8s--section "telemetry_sec" "Telemetry (trend: incoming pods, last 20s)" "telemetry_table")
    (a2ui-k8s--c "telemetry_table" "Table" "rows" (a2ui-k8s--p "/live/telemetry")
                 "columns" (vector (a2ui-obj "label" "Metric" "key" "metric")
                                   (a2ui-obj "label" (a2ui-k8s--p "/labels/out") "key" "out" "align" "right")
                                   (a2ui-obj "label" (a2ui-k8s--p "/labels/in") "key" "in" "align" "right")
                                   (a2ui-obj "label" "Trend" "key" "trend")
                                   (a2ui-obj "label" "SLO" "key" "slo")
                                   (a2ui-obj "label" "" "key" "ok")))
    (a2ui-k8s--section "pdb_sec" "PodDisruptionBudget" "pdb_col")
    (a2ui-k8s--c "pdb_col" "Column" "children" ["pdb_table" "pdb_hint"])
    (a2ui-k8s--table "pdb_table" "/live/pdb"
                     '(("PDB" "name") ("Min available" "min" "right") ("Healthy" "healthy" "right")
                       ("Disruptions allowed" "allowed" "right") ("Node drain" "drain")))
    (a2ui-k8s--c "pdb_hint" "Text" "variant" "caption"
                 "text" "A PDB gates evictions, such as a node drain, not the Deployment's own rollout; maxUnavailable 0 protects that.")
    (a2ui-k8s--section "events_sec" "Events" "events")
    (a2ui-k8s--c "events" "Code" "text" (a2ui-k8s--p "/live/events"))
    (a2ui-k8s--c "decision_card" "Card" "child" "decision_col")
    (a2ui-k8s--c "decision_col" "Column" "children" ["decision_title" "decision_text" "fix" "decision_buttons"])
    (a2ui-k8s--c "decision_title" "Text" "variant" "h3" "text" "⏸ Paused: your call")
    (a2ui-k8s--c "decision_text" "OrgText" "text" (a2ui-k8s--p "/decision/text"))
    (a2ui-k8s--c "fix" "Diff" "file" "k8s/checkout-api/deployment.yaml" "diff" (a2ui-k8s--p "/decision/diff")
                 "acceptAction" (a2ui-obj "event" (a2ui-obj "name" "apply_fix"))
                 "rejectAction" (a2ui-obj "event" (a2ui-obj "name" "reject_fix")))
    (a2ui-k8s--c "decision_buttons" "Row" "children" ["resume" "undo"])
    (a2ui-k8s--c "run_buttons" "Row" "children" ["pause" "abort"])
    (a2ui-k8s--c "pause" "Button" "child" "pause_label" "variant" "default"
                 "action" (a2ui-obj "event" (a2ui-obj "name" "toggle_pause")))
    (a2ui-k8s--c "pause_label" "Text" "text" (a2ui-k8s--p "/live/pauseLabel")))
   (a2ui-k8s--button "start" "Start rollout" "start" "primary"
                     (a2ui-obj "surge" (a2ui-k8s--p "/options/surge") "ask" (a2ui-k8s--p "/options/ask")))
   (a2ui-k8s--button "cancel" "Cancel" "cancel")
   (a2ui-k8s--button "hide_detail" "Hide" "hide_detail" "borderless")
   (a2ui-k8s--button "resume" "Resume as is" "resume")
   (a2ui-k8s--button "undo" "Roll back to 2.13.4" "rollback")
   (a2ui-k8s--button "abort" "Roll back now" "rollback")))

(defconst a2ui-k8s--manifest-diff
  "--- a/k8s/checkout-api/deployment.yaml
+++ b/k8s/checkout-api/deployment.yaml
@@ -28,7 +28,7 @@ spec:
     spec:
       containers:
         - name: checkout-api
-          image: registry.internal/checkout-api:2.13.4
+          image: registry.internal/checkout-api:2.14.0
           resources:
             requests:
               memory: 384Mi
"
  "The change being rolled out.")

(defconst a2ui-k8s--fix-diff
  "--- a/k8s/checkout-api/deployment.yaml
+++ b/k8s/checkout-api/deployment.yaml
@@ -32,7 +32,7 @@ spec:
           resources:
             requests:
-              memory: 384Mi
+              memory: 640Mi
             limits:
-              memory: 512Mi
+              memory: 768Mi
"
  "The memory patch the agent proposes.")

(defun a2ui-k8s--steps-data (run)
  "Return RUN's plan as table rows."
  (vconcat (mapcar (lambda (s) (a2ui-obj "status" (plist-get s :status) "step" (plist-get s :step)
                                         "detail" (plist-get s :detail)))
                   (a2ui-k8s-run-steps run))))

(defun a2ui-k8s--set-step (run id status &optional detail)
  "Set step ID of RUN to STATUS, and its DETAIL when given."
  (setf (a2ui-k8s-run-steps run)
        (mapcar (lambda (s)
                  (if (eq (plist-get s :id) id)
                      (let ((s (plist-put (copy-sequence s) :status status)))
                        (if detail (plist-put s :detail detail) s))
                    s))
                (a2ui-k8s-run-steps run))))

(defun a2ui-k8s--add-step (run id after step status detail)
  "Add step ID to RUN after step AFTER, with STEP, STATUS and DETAIL."
  (let (out)
    (dolist (s (a2ui-k8s-run-steps run))
      (push s out)
      (when (eq (plist-get s :id) after)
        (push (list :id id :step step :status status :detail detail) out)))
    (setf (a2ui-k8s-run-steps run) (nreverse out))))

(defun a2ui-k8s--root-children (run)
  "Return the root's children for RUN's phase."
  (pcase (a2ui-k8s-run-phase run)
    ('plan ["title" "subtitle" "note" "plan_sec" "change_sec" "options_sec" "plan_buttons"])
    ('cancelled ["title" "note"])
    (phase
     (vconcat '("title" "status" "progress")
              (when (eq phase 'decision) '("decision_card"))
              '("note" "plan_sec" "rs_sec" "pods_sec")
              (when (a2ui-k8s-run-detail-pod run) '("detail_sec"))
              '("telemetry_sec" "pdb_sec" "events_sec")
              (when (memq phase '(rolling verify)) '("run_buttons"))))))

(defun a2ui-k8s--layout (run)
  "Resend the root's and the decision card's children when they changed."
  (let ((root (a2ui-k8s--root-children run))
        (decision (if (a2ui-k8s-run-hide-fix run)
                      ["decision_title" "decision_text" "decision_buttons"]
                    ["decision_title" "decision_text" "fix" "decision_buttons"])))
    (unless (equal (cons root decision) (a2ui-k8s-run-root run))
      (setf (a2ui-k8s-run-root run) (cons root decision))
      (a2ui-k8s--send run "updateComponents"
                      (a2ui-obj "components"
                                (vector (a2ui-k8s--c "root" "Column" "children" root)
                                        (a2ui-k8s--c "decision_col" "Column" "children" decision)))))))

(defun a2ui-k8s--note (run text)
  "Show TEXT, Org markup, as the agent's note on RUN."
  (a2ui-k8s--data run "/note" text))

(defun a2ui-k8s--status (run)
  "Return the status line of RUN."
  (let* ((w (a2ui-k8s-run-world run))
         (target (a2ui-k8s-world-target w)))
    (pcase (a2ui-k8s-run-phase run)
      ('decision "⏸ Paused by the agent: waiting for your decision")
      ('verify (format "✓ All %d pods on %s; checking SLOs for %ds more"
                       (a2ui-k8s-world-replicas w) (a2ui-k8s-rs-image target) (a2ui-k8s-run-verify-left run)))
      ('done (if (a2ui-k8s-run-rolled-back run)
                 "↩ Rolled back: 2.13.4 serving on all pods"
               (format "✓ Rollout complete: revision %d serving on all pods" (a2ui-k8s-rs-revision target))))
      (_ (if (a2ui-k8s-world-paused w)
             "⏸ Paused by you"
           (format "⟳ Progressing towards revision %d (%s, %dMi limit)"
                   (a2ui-k8s-rs-revision target) (a2ui-k8s-rs-image target) (a2ui-k8s-rs-limit target)))))))

(defun a2ui-k8s--progress (w)
  "Return the progress line of world W."
  (let* ((target (a2ui-k8s-world-target w))
         (replicas (a2ui-k8s-world-replicas w))
         (updated (length (a2ui-k8s--live w target)))
         (ready (seq-count #'a2ui-k8s-pod-ready (a2ui-k8s--live w target))))
    (format "Updated %s %d/%d   Ready %d/%d   Available %d/%d   t+%ds"
            (a2ui-k8s--bar ready replicas 12) updated replicas ready replicas
            (a2ui-k8s--healthy w) replicas (a2ui-k8s-world-tick w))))

(defun a2ui-k8s--pods-data (w)
  "Return W's pods as table rows."
  (vconcat
   (mapcar (lambda (p)
             (let ((rs (a2ui-k8s-pod-rs p)))
               (a2ui-obj "pod" (a2ui-k8s-pod-name p)
                         "rev" (a2ui-k8s-rs-revision rs)
                         "status" (pcase (a2ui-k8s-pod-phase p)
                                    ("OOMKilled" "✗ OOMKilled")
                                    ("CrashLoopBackOff" "✗ CrashLoopBackOff")
                                    ("Running" (if (a2ui-k8s-pod-ready p) "● Running" "○ Running"))
                                    (phase (concat "· " phase)))
                         "ready" (if (a2ui-k8s-pod-ready p) "1/1" "0/1")
                         "restarts" (a2ui-k8s-pod-restarts p)
                         "memory" (if (> (a2ui-k8s-pod-memory p) 0)
                                      (format "%s %3d/%dMi%s"
                                              (a2ui-k8s--bar (a2ui-k8s-pod-memory p) (a2ui-k8s-rs-limit rs) 6)
                                              (round (a2ui-k8s-pod-memory p)) (a2ui-k8s-rs-limit rs)
                                              (if (a2ui-k8s--pressured-p p) " ⚠" ""))
                                    "")
                         "node" (a2ui-k8s-pod-node p)
                         "age" (a2ui-k8s--age (a2ui-k8s-pod-age p)))))
           (seq-sort-by (lambda (p) (list (a2ui-k8s-rs-revision (a2ui-k8s-pod-rs p)) (a2ui-k8s-pod-name p)))
                        (lambda (a b) (or (< (car a) (car b))
                                          (and (= (car a) (car b)) (string< (cadr a) (cadr b)))))
                        (a2ui-k8s-world-pods w)))))

(defun a2ui-k8s--rses-data (w)
  "Return W's ReplicaSets as table rows."
  (vconcat
   (mapcar (lambda (rs)
             (let ((live (a2ui-k8s--live w rs)))
               (a2ui-obj "name" (a2ui-k8s-rs-name rs) "rev" (a2ui-k8s-rs-revision rs)
                         "image" (a2ui-k8s-rs-image rs) "limit" (format "%dMi" (a2ui-k8s-rs-limit rs))
                         "desired" (a2ui-k8s-rs-desired rs) "current" (length live)
                         "ready" (seq-count #'a2ui-k8s-pod-ready live)
                         "role" (cond ((eq rs (a2ui-k8s-world-target w)) "◀ incoming")
                                      ((> (+ (a2ui-k8s-rs-desired rs) (length live)) 0) "outgoing")
                                      (t "")))))
           (seq-filter (lambda (rs) (or (eq rs (a2ui-k8s-world-target w))
                                        (> (a2ui-k8s-rs-desired rs) 0)
                                        (seq-find (lambda (p) (eq (a2ui-k8s-pod-rs p) rs))
                                                  (a2ui-k8s-world-pods w))))
                       (a2ui-k8s-world-rses w)))))

(defun a2ui-k8s--telemetry-data (w)
  "Return W's telemetry as table rows."
  (let* ((h (car (a2ui-k8s-world-history w)))
         (in (plist-get h :in))
         (out (plist-get h :out))
         (target (a2ui-k8s-world-target w))
         (restarts (apply #'+ (mapcar #'a2ui-k8s-pod-restarts (a2ui-k8s--live w target))))
         (fmt (lambda (side key format)
                (let ((v (plist-get side key))) (if v (format format v) "—"))))
         (ok (lambda (v limit) (cond ((null v) "") ((< v limit) "✓") (t "✗")))))
    (vector
     (a2ui-obj "metric" "Requests/s" "out" (funcall fmt out :rps "%.0f") "in" (funcall fmt in :rps "%.0f")
               "trend" (a2ui-k8s--spark (a2ui-k8s--series w :in :rps) 1300) "slo" "" "ok" "")
     (a2ui-obj "metric" "5xx rate" "out" (funcall fmt out :err "%.2f%%") "in" (funcall fmt in :err "%.2f%%")
               "trend" (a2ui-k8s--spark (a2ui-k8s--series w :in :err) 5) "slo" "< 1%"
               "ok" (funcall ok (plist-get in :err) 1.0))
     (a2ui-obj "metric" "p99 latency" "out" (funcall fmt out :p99 "%.0f ms") "in" (funcall fmt in :p99 "%.0f ms")
               "trend" (a2ui-k8s--spark (a2ui-k8s--series w :in :p99) 1000) "slo" "< 400 ms"
               "ok" (funcall ok (plist-get in :p99) 400))
     (a2ui-obj "metric" "Memory (mean)" "out" (funcall fmt out :mem "%.0fMi") "in" (funcall fmt in :mem "%.0fMi")
               "trend" (a2ui-k8s--spark (a2ui-k8s--series w :in :mem) (a2ui-k8s-rs-limit target))
               "slo" (format "< %dMi" (a2ui-k8s-rs-limit target))
               "ok" (funcall ok (plist-get in :mem) (* 0.88 (a2ui-k8s-rs-limit target))))
     (a2ui-obj "metric" "Restarts" "out" "" "in" (number-to-string restarts)
               "trend" "" "slo" "0" "ok" (if (zerop restarts) "✓" "✗")))))

(defun a2ui-k8s--pdb-data (w)
  "Return W's PodDisruptionBudget as a table row."
  (let ((healthy (a2ui-k8s--healthy w)))
    (vector (a2ui-obj "name" "checkout-api-pdb" "min" (a2ui-k8s-world-min-available w)
                      "healthy" healthy
                      "allowed" (max 0 (- healthy (a2ui-k8s-world-min-available w)))
                      "drain" (cond ((a2ui-k8s-world-drained w) "✓ node removed")
                                    ((and (<= healthy (a2ui-k8s-world-min-available w))
                                          (> (a2ui-k8s-world-blocked w) 0))
                                     (format "✗ blocked by PDB (%d %s)" (a2ui-k8s-world-blocked w)
                                             (if (= 1 (a2ui-k8s-world-blocked w)) "try" "tries")))
                                    (t (format "draining %s" a2ui-k8s--drain-node)))))))

(defun a2ui-k8s--events-text (w)
  "Return W's newest events as kubectl would print them."
  (mapconcat (pcase-lambda (`(,tick ,type ,reason ,object ,message))
               (format "t+%-4s %-7s %-17s %-38s %s" (format "%ds" tick) type reason object message))
             (reverse (seq-take (a2ui-k8s-world-events w) 12))
             "\n"))

(defun a2ui-k8s--describe (w name)
  "Return `kubectl describe' output for pod NAME of W, or nil when it's gone."
  (when-let* ((p (seq-find (lambda (p) (equal (a2ui-k8s-pod-name p) name)) (a2ui-k8s-world-pods w))))
    (let ((rs (a2ui-k8s-pod-rs p))
          (phase (a2ui-k8s-pod-phase p)))
      (concat
       (format "Name:          %s\nNamespace:     prod\nNode:          %s\nControlled By: ReplicaSet/%s\n"
               name (a2ui-k8s-pod-node p) (a2ui-k8s-rs-name rs))
       (format "Containers:\n  checkout-api:\n    Image:          %s%s\n" a2ui-k8s--image (a2ui-k8s-rs-image rs))
       (pcase phase
         ("Running" "    State:          Running\n")
         ((or "Pending" "ContainerCreating") (format "    State:          Waiting\n      Reason:       %s\n" phase))
         ("OOMKilled" "    State:          Terminated\n      Reason:       OOMKilled\n      Exit Code:    137\n")
         ("CrashLoopBackOff" "    State:          Waiting\n      Reason:       CrashLoopBackOff\n")
         ("Terminating" "    State:          Terminating\n"))
       (if (and (a2ui-k8s-pod-last-reason p) (not (equal phase "OOMKilled")))
           "    Last State:     Terminated\n      Reason:       OOMKilled\n      Exit Code:    137\n"
         "")
       (format "    Ready:          %s\n    Restart Count:  %d\n"
               (if (a2ui-k8s-pod-ready p) "True" "False") (a2ui-k8s-pod-restarts p))
       (format "    Limits:\n      memory:       %dMi\n    Requests:\n      memory:       %dMi\n"
               (a2ui-k8s-rs-limit rs) (a2ui-k8s-rs-request rs))
       (if (> (a2ui-k8s-pod-memory p) 0)
           (format "    Memory now:     %dMi\n" (round (a2ui-k8s-pod-memory p)))
         "")))))

(defun a2ui-k8s--render (run)
  "Send RUN's current state to the surface."
  (let ((w (a2ui-k8s-run-world run)))
    (a2ui-k8s--layout run)
    (a2ui-k8s--data run "/plan" (a2ui-k8s--steps-data run))
    (unless (eq (a2ui-k8s-run-phase run) 'plan)
      (a2ui-k8s--data
       run "/live"
       (a2ui-obj "status" (a2ui-k8s--status run)
                 "progress" (a2ui-k8s--progress w)
                 "rses" (a2ui-k8s--rses-data w)
                 "pods" (a2ui-k8s--pods-data w)
                 "telemetry" (a2ui-k8s--telemetry-data w)
                 "pdb" (a2ui-k8s--pdb-data w)
                 "events" (a2ui-k8s--events-text w)
                 "pauseLabel" (if (a2ui-k8s-world-paused w) "Resume" "Pause")))
      (when-let* ((name (a2ui-k8s-run-detail-pod run)))
        (a2ui-k8s--data run "/detail"
                        (a2ui-obj "title" (concat "kubectl describe pod " name)
                                  "text" (or (a2ui-k8s--describe w name)
                                             "The pod is gone: it was deleted.")))))))

(defun a2ui-k8s--crashing-pod (run)
  "Return the incoming pod of RUN that restarted most, or nil."
  (let ((w (a2ui-k8s-run-world run)))
    (car (seq-sort-by #'a2ui-k8s-pod-restarts #'>
                      (seq-filter (lambda (p) (> (a2ui-k8s-pod-restarts p) 0))
                                  (a2ui-k8s--live w (a2ui-k8s-world-target w)))))))

(defun a2ui-k8s--breach (run)
  "Return why RUN's incoming pods breach their SLOs, or nil."
  (let* ((w (a2ui-k8s-run-world run))
         (target (a2ui-k8s-world-target w))
         (restarts (apply #'+ (mapcar #'a2ui-k8s-pod-restarts (a2ui-k8s--live w target))))
         (now (plist-get (nth 0 (a2ui-k8s-world-history w)) :in))
         (before (plist-get (nth 1 (a2ui-k8s-world-history w)) :in))
         (over (lambda (key limit) (and now before (> (plist-get now key) limit)
                                        (> (plist-get before key) limit)))))
    (unless (a2ui-k8s-run-rolled-back run)
      (cond ((> restarts (a2ui-k8s-run-tolerated run))
             (let ((pod (a2ui-k8s--crashing-pod run)))
               (format "=%s= was *OOMKilled* (exit 137, %d restart%s)"
                       (a2ui-k8s-pod-name pod) (a2ui-k8s-pod-restarts pod)
                       (if (= 1 (a2ui-k8s-pod-restarts pod)) "" "s"))))
            ((a2ui-k8s-run-resumed run) nil)
            ((funcall over :err 1.0)
             (format "incoming 5xx has been over 1%% for 2s (%.2f%%)" (plist-get now :err)))
            ((funcall over :p99 400)
             (format "incoming p99 has been over 400 ms for 2s (%.0f ms)" (plist-get now :p99)))))))

(defun a2ui-k8s--decide (run reason)
  "Pause RUN for REASON and ask the user what to do."
  (let* ((w (a2ui-k8s-run-world run))
         (target (a2ui-k8s-world-target w))
         (out (plist-get (car (a2ui-k8s-world-history w)) :out))
         (healthy (a2ui-k8s--healthy w)))
    (setf (a2ui-k8s-world-paused w) t
          (a2ui-k8s-run-phase run) 'decision
          (a2ui-k8s-run-pause-reason run) reason)
    (a2ui-k8s--event w "Normal" "Paused" "deployment/checkout-api" "rollout paused by agent (kubectl rollout pause)")
    (a2ui-k8s--set-step run 'roll "⏸" (format "paused at %d/%d updated"
                                             (length (a2ui-k8s--live w target)) (a2ui-k8s-world-replicas w)))
    (a2ui-k8s--set-step run 'watch "✗" (replace-regexp-in-string "[=*]" "" reason))
    (a2ui-k8s--data
     run "/decision"
     (a2ui-obj
      "diff" a2ui-k8s--fix-diff
      "text"
      (concat
       (format "I paused the rollout: %s.\n\n" reason)
       (if (a2ui-k8s-run-fixed run)
           "It is still running out of memory at 768Mi, so the cache needs a bound, not more memory.  I'd roll back.\n"
         (format "On =2.14.0= memory climbs about 40Mi a second under load until it hits the =%dMi= limit; =2.13.4= sits near %s.  The new in-process price cache is the likely cause: it plateaus around 640Mi.  Before the crash the incoming pods were faster, p99 %s against %s.\n"
                 (a2ui-k8s-rs-limit target)
                 (if out (format "%.0fMi" (plist-get out :mem)) "300Mi")
                 (a2ui-k8s--best w :in) (a2ui-k8s--best w :out)))
       (format "\nOnly %d pods are healthy against =minAvailable: 5=, so the PDB is %s the autoscaler's drain of =%s=.\n\n"
               healthy (if (<= healthy 5) "blocking" "holding back") a2ui-k8s--drain-node)
       (if (or (a2ui-k8s-run-fixed run) (a2ui-k8s-run-hide-fix run))
           "- *Resume as is* if you think it's transient\n- *Roll back* to =2.13.4="
         "- *Accept* the patch below to raise the limit to 768Mi; that makes a new ReplicaSet and I carry on\n- *Resume as is* if you think it's transient\n- *Roll back* to =2.13.4="))))
    (when (a2ui-k8s-run-fixed run) (setf (a2ui-k8s-run-hide-fix run) t))
    (a2ui-k8s--note run "/Waiting for you: see the card above./")))

(defun a2ui-k8s--rollback (run why)
  "Roll RUN back to the original ReplicaSet, saying WHY."
  (let ((w (a2ui-k8s-run-world run))
        (original (a2ui-k8s-run-original run)))
    (setf (a2ui-k8s-world-target w) original
          (a2ui-k8s-world-paused w) nil
          (a2ui-k8s-run-rolled-back run) t
          (a2ui-k8s-run-phase run) 'rolling)
    (a2ui-k8s--event w "Normal" "RolledBack" "deployment/checkout-api"
                     (format "rolled back to revision %d (kubectl rollout undo)" (a2ui-k8s-rs-revision original)))
    (a2ui-k8s--set-step run 'roll "–" "stopped")
    (a2ui-k8s--set-step run 'watch "–" "stopped")
    (a2ui-k8s--add-step run 'rollback 'watch "Roll back to 2.13.4 (revision 7)" "⟳" why)
    (a2ui-k8s--data run "/labels" (a2ui-obj "out" "Outgoing" "in" "Incoming 2.13.4"))
    (a2ui-k8s--note run (format "/Rolling back: %s.  2.13.4 pods come back first; the crashing ones go at once./" why))))

(defun a2ui-k8s--finish (run)
  "End RUN with a summary."
  (let* ((w (a2ui-k8s-run-world run))
         (target (a2ui-k8s-world-target w))
         (in (plist-get (car (a2ui-k8s-world-history w)) :in)))
    (setf (a2ui-k8s-run-phase run) 'done)
    (a2ui-k8s--set-step run 'verify "✓" (format "%.2f%% 5xx, p99 %.0f ms" (plist-get in :err) (plist-get in :p99)))
    (a2ui-k8s--note
     run
     (if (a2ui-k8s-run-rolled-back run)
         (format "*Rolled back.*  All 6 pods run =2.13.4= again, at %.2f%% 5xx.  Before retrying 2.14.0, bound the price cache (size or TTL) or raise the memory limit, and load test a single pod.%s"
                 (plist-get in :err)
                 (if (a2ui-k8s-world-drained w) "  The node drain finished meanwhile." ""))
       (format "*Done.*  =checkout-api= runs =2.14.0= on all 6 pods with a %dMi limit (revision %d).  Incoming p99 is %.0f ms, faster than 2.13.4: the price cache pays for itself once it has the memory.  5xx %.2f%%.\n\nFollow-ups:\n- Put the %dMi limit in the Helm chart too, or the next deploy reverts it\n- Add an alert on container memory above 85%% of the limit%s"
               (a2ui-k8s-rs-limit target) (a2ui-k8s-rs-revision target) (plist-get in :p99) (plist-get in :err)
               (a2ui-k8s-rs-limit target)
               (if (a2ui-k8s-world-drained w)
                   (format "\n- The drain of =%s= went through once the PDB allowed it" a2ui-k8s--drain-node)
                 ""))))
    (a2ui-k8s--stop run)))

(defun a2ui-k8s--tick (run)
  "Advance RUN by one simulated second."
  (let ((w (a2ui-k8s-run-world run)))
    (a2ui-k8s--step w)
    (pcase (a2ui-k8s-run-phase run)
      ('rolling
       (let ((target (a2ui-k8s-world-target w)))
         (unless (a2ui-k8s-world-paused w)
           (a2ui-k8s--set-step run (if (a2ui-k8s-run-rolled-back run) 'rollback 'roll) "⟳"
                               (format "%d/%d updated, %d ready"
                                       (length (a2ui-k8s--live w target)) (a2ui-k8s-world-replicas w)
                                       (seq-count #'a2ui-k8s-pod-ready (a2ui-k8s--live w target)))))
         (when-let* ((reason (and (not (a2ui-k8s-world-paused w)) (a2ui-k8s--breach run))))
           (if (a2ui-k8s-run-ask run)
               (a2ui-k8s--decide run reason)
             (a2ui-k8s--rollback run (replace-regexp-in-string "[=*]" "" reason))))
         (when (and (eq (a2ui-k8s-run-phase run) 'rolling) (a2ui-k8s--complete-p w))
           (a2ui-k8s--set-step run (if (a2ui-k8s-run-rolled-back run) 'rollback 'roll) "✓"
                               (format "%d/%d on revision %d" (a2ui-k8s-world-replicas w)
                                       (a2ui-k8s-world-replicas w) (a2ui-k8s-rs-revision target)))
           (unless (a2ui-k8s-run-rolled-back run)
             (a2ui-k8s--set-step run 'watch "✓" "no breach on the incoming pods"))
           (setf (a2ui-k8s-run-phase run) 'verify (a2ui-k8s-run-verify-left run) 5)
           (a2ui-k8s--set-step run 'verify "⟳" "5s of SLOs on every pod")
           (a2ui-k8s--note run "/Every pod is updated.  Watching the SLOs for a few more seconds before calling it done./"))))
      ('verify
       (cl-decf (a2ui-k8s-run-verify-left run))
       (when (<= (a2ui-k8s-run-verify-left run) 0)
         (a2ui-k8s--finish run))))
    (a2ui-k8s--render run)))

;;;; Actions

(defun a2ui-k8s--number (value default)
  "Return VALUE as an integer from 1 to 3, or DEFAULT."
  (if (numberp value) (max 1 (min 3 (round value))) default))

(defun a2ui-k8s--handle (run name context)
  "Run the action NAME with CONTEXT on RUN."
  (let ((w (a2ui-k8s-run-world run)))
    (pcase name
      ("start"
       (when (eq (a2ui-k8s-run-phase run) 'plan)
         (let ((new (cadr (a2ui-k8s-world-rses w))))
           (setf (a2ui-k8s-world-surge w) (a2ui-k8s--number (gethash "surge" context) 1)
                 (a2ui-k8s-run-ask run) (a2ui-true-p (gethash "ask" context))
                 (a2ui-k8s-world-target w) new
                 (a2ui-k8s-run-phase run) 'rolling)
           (a2ui-k8s--event w "Normal" "Updated" "deployment/checkout-api"
                            (format "image set to %s2.14.0 (revision 8)" a2ui-k8s--image))
           (a2ui-k8s--set-step run 'apply "✓" "kubectl apply: revision 8")
           (a2ui-k8s--set-step run 'roll "⟳" (format "maxSurge %d" (a2ui-k8s-world-surge w)))
           (a2ui-k8s--set-step run 'watch "⟳" "5xx < 1%, p99 < 400 ms, no restarts")
           (a2ui-k8s--note run (format "/Rolling with maxSurge %d.  Watching 5xx, p99, memory and restarts on the incoming pods%s./"
                                       (a2ui-k8s-world-surge w)
                                       (if (a2ui-k8s-run-ask run) "; I'll ask you if they breach"
                                         "; I'll roll back on a breach")))
           (a2ui-k8s--render run)
           (a2ui-k8s--start-timer run))))
      ("cancel"
       (when (eq (a2ui-k8s-run-phase run) 'plan)
         (setf (a2ui-k8s-run-phase run) 'cancelled)
         (a2ui-k8s--note run "Cancelled.  Nothing was applied.")
         (a2ui-k8s--render run)))
      ("toggle_pause"
       (when (eq (a2ui-k8s-run-phase run) 'rolling)
         (setf (a2ui-k8s-world-paused w) (not (a2ui-k8s-world-paused w)))
         (a2ui-k8s--event w "Normal" (if (a2ui-k8s-world-paused w) "Paused" "Resumed") "deployment/checkout-api"
                          (if (a2ui-k8s-world-paused w) "rollout paused by user" "rollout resumed by user"))
         (a2ui-k8s--set-step run (if (a2ui-k8s-run-rolled-back run) 'rollback 'roll)
                             (if (a2ui-k8s-world-paused w) "⏸" "⟳")
                             (if (a2ui-k8s-world-paused w) "paused by you" "resumed"))
         (a2ui-k8s--render run)))
      ("rollback"
       (when (memq (a2ui-k8s-run-phase run) '(rolling decision))
         (unless (a2ui-k8s-run-rolled-back run)
           (a2ui-k8s--rollback run "you asked me to"))
         (a2ui-k8s--render run)))
      ("resume"
       (when (eq (a2ui-k8s-run-phase run) 'decision)
         (let ((target (a2ui-k8s-world-target w)))
           (setf (a2ui-k8s-world-paused w) nil
                 (a2ui-k8s-run-resumed run) t
                 (a2ui-k8s-run-phase run) 'rolling
                 (a2ui-k8s-run-tolerated run)
                 (+ 3 (apply #'+ (mapcar #'a2ui-k8s-pod-restarts (a2ui-k8s--live w target)))))
           (a2ui-k8s--event w "Normal" "Resumed" "deployment/checkout-api" "rollout resumed (kubectl rollout resume)")
           (a2ui-k8s--set-step run 'watch "⚠" "resumed as is; I'll stop again after 3 more restarts")
           (a2ui-k8s--note run "/Resumed as is.  I'm ignoring the error rate now, but I'll stop again if the pods keep restarting./")
           (a2ui-k8s--render run))))
      ("apply_fix"
       (when (and (eq (a2ui-k8s-run-phase run) 'decision) (not (a2ui-k8s-run-fixed run)))
         (let ((fixed (a2ui-k8s--rs :name "checkout-api-84c6d7b5f" :image "2.14.0"
                                    :limit 768 :request 640 :revision 9)))
           (setf (a2ui-k8s-world-rses w) (append (a2ui-k8s-world-rses w) (list fixed))
                 (a2ui-k8s-world-target w) fixed
                 (a2ui-k8s-world-paused w) nil
                 (a2ui-k8s-run-fixed run) t
                 (a2ui-k8s-run-tolerated run) 0
                 (a2ui-k8s-run-resumed run) nil
                 (a2ui-k8s-run-phase run) 'rolling)
           (a2ui-k8s--event w "Normal" "Updated" "deployment/checkout-api"
                            "memory limit 512Mi → 768Mi, request 384Mi → 640Mi (revision 9); rollout resumed")
           (a2ui-k8s--add-step run 'patch 'apply "Raise memory to 768Mi (revision 9)" "✓" "kubectl apply, accepted by you")
           (a2ui-k8s--set-step run 'watch "⟳" "5xx < 1%, p99 < 400 ms, no restarts")
           (a2ui-k8s--data run "/labels" (a2ui-obj "out" "Outgoing" "in" "Incoming 768Mi"))
           (a2ui-k8s--note run "/Applied the patch.  Revision 9 replaces both the 2.13.4 pods and the crashing 512Mi ones; the crashing ones go first./")
           (a2ui-k8s--render run))))
      ("reject_fix"
       (when (eq (a2ui-k8s-run-phase run) 'decision)
         (setf (a2ui-k8s-run-hide-fix run) t)
         (a2ui-k8s--decide run (a2ui-k8s-run-pause-reason run))
         (a2ui-k8s--render run)))
      ("describe_pod"
       (when-let* ((pod (gethash "pod" context)))
         (setf (a2ui-k8s-run-detail-pod run) pod)
         (a2ui-k8s--render run)))
      ("hide_detail"
       (setf (a2ui-k8s-run-detail-pod run) nil)
       (a2ui-k8s--render run)))))

;;;; Running it

(defun a2ui-k8s--alive-p (run)
  "Return non-nil while RUN's surface is still shown."
  (a2ui-session-surface (a2ui-k8s-run-session run) a2ui-k8s--surface))

(defun a2ui-k8s--stop (run)
  "Stop RUN's clock."
  (when (timerp (a2ui-k8s-run-timer run))
    (cancel-timer (a2ui-k8s-run-timer run)))
  (setf (a2ui-k8s-run-timer run) nil))

(defun a2ui-k8s--start-timer (run)
  "Tick RUN every `a2ui-k8s-tick-seconds' while its surface lives."
  (a2ui-k8s--stop run)
  (when a2ui-k8s-tick-seconds
    (setf (a2ui-k8s-run-timer run)
          (run-at-time a2ui-k8s-tick-seconds a2ui-k8s-tick-seconds
                       (lambda ()
                         (if (a2ui-k8s--alive-p run)
                             (a2ui-k8s--tick run)
                           (a2ui-k8s--stop run)))))))

(defun a2ui-k8s-start (&optional session)
  "Show the rollout plan on SESSION, a new one by default; return the run."
  (when a2ui-k8s--current (a2ui-k8s--stop a2ui-k8s--current))
  (let* ((run (a2ui-k8s--run :world (a2ui-k8s--make-world)))
         (session (or session
                      (let ((s (a2ui-session-create :name "rollout-agent")))
                        (a2ui-vui-attach s)
                        s))))
    (setf (a2ui-k8s-run-session run) session
          (a2ui-k8s-run-original run) (car (a2ui-k8s-world-rses (a2ui-k8s-run-world run)))
          (a2ui-session-send-action-fn session)
          (lambda (message _metadata)
            (when-let* ((action (gethash "action" message)))
              (funcall a2ui-k8s--defer
                       (lambda ()
                         (when (a2ui-k8s--alive-p run)
                           (a2ui-k8s--handle run (gethash "name" action)
                                             (or (gethash "context" action) (a2ui-obj)))))))))
    (setf (a2ui-k8s-run-steps run)
          (list (list :id 'preflight :status "✓" :step "Pre-flight checks"
                      :detail "6/6 ready · PDB allows 1 disruption · HPA pinned at 6")
                (list :id 'apply :status "·" :step "Apply image 2.14.0 (revision 8)" :detail "")
                (list :id 'roll :status "·" :step "Roll pods" :detail "surge first, then retire 2.13.4")
                (list :id 'watch :status "·" :step "Watch incoming pods"
                      :detail "5xx < 1%, p99 < 400 ms, no restarts")
                (list :id 'verify :status "·" :step "Verify" :detail "5s of SLOs on every pod")))
    (a2ui-k8s--send run "createSurface"
                    (a2ui-obj "catalogId" a2ui-emacs-catalog-id
                              "theme" (a2ui-obj "agentDisplayName" "Rollout agent")))
    (a2ui-k8s--send run "updateComponents" (a2ui-obj "components" (vconcat (a2ui-k8s--components))))
    (a2ui-k8s--send run "updateDataModel"
                    (a2ui-obj "value"
                              (a2ui-obj "manifest" a2ui-k8s--manifest-diff
                                        "options" (a2ui-obj "surge" 1 "ask" t)
                                        "labels" (a2ui-obj "out" "Outgoing 2.13.4" "in" "Incoming 2.14.0")
                                        "note" (concat
                                                "I'll roll =prod/checkout-api= from =2.13.4= to =2.14.0=.  "
                                                "With =maxUnavailable: 0= all 6 replicas keep serving: each new pod must be ready before an old one goes.\n\n"
                                                "The cluster-autoscaler is draining =ip-10-0-3-17= at the same time.  "
                                                "The PDB (=minAvailable: 5=) doesn't gate the rollout, but it gates that drain, so I'll watch both.")
                                        "live" (a2ui-obj)
                                        "decision" (a2ui-obj "text" "" "diff" "")
                                        "detail" (a2ui-obj "title" "" "text" ""))))
    (a2ui-k8s--render run)
    (setq a2ui-k8s--current run)))

;;;###autoload
(defun a2ui-example-k8s-rollout ()
  "Show a simulated Kubernetes rollout run by a scripted agent."
  (interactive)
  (a2ui-k8s-start)
  nil)

(provide 'k8s-rollout)
;;; k8s-rollout.el ends here
