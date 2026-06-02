;;; agent-shell-hud.el --- Workspace HUD adapter for Agent Shell -*- lexical-binding: t; -*-

;; Author: emacs-egui-panel
;; Version: 0.1.0
;; Keywords: convenience, tools, agents
;; Package-Requires: ((emacs "29.1") (workspace-hud "0.1.0") (agent-shell "0.50.1"))

;;; Commentary:
;;
;; Provides a bridge between `agent-shell' and `workspace-hud'.
;; It subscribes to ACP agent shell events and pushes a real-time
;; "Agent" section containing active tool state, files touched,
;; turn summary, and token usage into the workspace status HUD.
;;
;; Usage: Enable the minor mode globally in your init file:
;;   (agent-shell-hud-mode 1)

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'workspace-hud)
(require 'agent-shell)

(defgroup agent-shell-hud nil
  "Workspace HUD adapter for Agent Shell."
  :group 'tools
  :prefix "agent-shell-hud-")

;; Buffer-local variables for state tracking
(defvar-local agent-shell-hud--files-touched nil
  "List of project-relative paths modified during the active turn.")

(defvar-local agent-shell-hud--last-action "Ready"
  "Phrase describing the current agent activity.")

(defvar-local agent-shell-hud--status "ok"
  "Active status vocabulary mapping to HUD colors.")

(defvar-local agent-shell-hud--subscription-token nil
  "Active subscription token for the agent-shell buffer.")

(defvar-local agent-shell-hud--turn-start-time nil
  "Time when the current agent turn started.")

(defvar-local agent-shell-hud--elapsed-timer nil
  "Timer that ticks every second to update elapsed time in the HUD.")

;; ---------------------------------------------------------------------------
;; Event Mapping & HUD Push
;; ---------------------------------------------------------------------------

(defun agent-shell-hud--get-usage (buf)
  "Calculate context usage percentage for agent-shell BUF."
  (let* ((state (buffer-local-value 'agent-shell--state buf))
         (usage (map-elt state :usage))
         (used (map-elt usage :context-used))
         (size (map-elt usage :context-size)))
    (if (and used size (> size 0))
        (format "%d%% used" (round (* (/ (float used) (float size)) 100.0)))
      "")))

(defun agent-shell-hud--extract-file (tool-call)
  "Extract file path from TOOL-CALL."
  (let* ((diff (map-elt tool-call :diff))
         (diff-file (map-elt diff :file))
         (raw-input (map-elt tool-call :raw-input))
         (input-file (and raw-input
                          (or (map-elt raw-input 'TargetFile)
                              (map-elt raw-input :TargetFile)
                              (map-elt raw-input "TargetFile")
                              (map-elt raw-input 'path)
                              (map-elt raw-input :path)
                              (map-elt raw-input "path")
                              (map-elt raw-input 'filepath)
                              (map-elt raw-input :filepath)
                              (map-elt raw-input "filepath")
                              (map-elt raw-input 'fileName)
                              (map-elt raw-input :fileName)
                              (map-elt raw-input "fileName")
                              (map-elt raw-input 'AbsolutePath)
                              (map-elt raw-input :AbsolutePath)
                              (map-elt raw-input "AbsolutePath")))))
    (or diff-file input-file)))

(defun agent-shell-hud--add-touched-file (file-path)
  "Add FILE-PATH to `agent-shell-hud--files-touched', cleaned relative to project root.
Ignore directory paths."
  (when (and file-path (stringp file-path) (> (length file-path) 0))
    (let ((expanded (expand-file-name file-path)))
      (unless (file-directory-p expanded)
        (let* ((proj-root (ignore-errors (agent-shell-cwd)))
               (proj-root (and proj-root (file-name-as-directory proj-root)))
               (clean-path (if (and proj-root (string-prefix-p proj-root expanded))
                               (substring expanded (length proj-root))
                             (file-name-nondirectory expanded))))
          (add-to-list 'agent-shell-hud--files-touched clean-path))))))

(defun agent-shell-hud--format-elapsed (buf)
  "Return a MM:SS string for time since turn started in BUF, or empty string."
  (if (and (buffer-live-p buf)
           (buffer-local-value 'agent-shell-hud--turn-start-time buf))
      (let* ((secs (floor (float-time
                           (time-subtract (current-time)
                                          (buffer-local-value 'agent-shell-hud--turn-start-time buf)))))
             (mins (/ secs 60))
             (remainder (% secs 60)))
        (format "%d:%02d" mins remainder))
    ""))

(defun agent-shell-hud--elapsed-tick (buf)
  "Called every second to refresh the HUD elapsed display for BUF."
  (if (and (buffer-live-p buf)
           (buffer-local-value 'agent-shell-hud--turn-start-time buf))
      (agent-shell-hud--push-status buf)
    (agent-shell-hud--stop-elapsed-timer buf)))

(defun agent-shell-hud--start-elapsed-timer (buf)
  "Start the 1-second tick timer for BUF."
  (agent-shell-hud--stop-elapsed-timer buf)
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq-local agent-shell-hud--elapsed-timer
                  (run-with-timer 1 1 #'agent-shell-hud--elapsed-tick buf)))))

(defun agent-shell-hud--stop-elapsed-timer (buf)
  "Cancel the tick timer for BUF if active."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when agent-shell-hud--elapsed-timer
        (cancel-timer agent-shell-hud--elapsed-timer)
        (setq-local agent-shell-hud--elapsed-timer nil)))))

(defun agent-shell-hud--push-status (buf)
  "Construct and push the Agent section to `workspace-hud' for BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((state agent-shell--state)
             (agent-config (map-elt state :agent-config))
             (agent-name (or (map-elt agent-config :mode-line-name) "Agent"))
             (proj-root (ignore-errors (agent-shell-cwd)))
             (proj-name (if proj-root
                            (file-name-nondirectory (directory-file-name proj-root))
                          "Unknown"))
             (files-count (length agent-shell-hud--files-touched))
             (files-str (if (> files-count 0)
                            (format "%d touched" files-count)
                          "0 touched"))
             (elapsed-str (agent-shell-hud--format-elapsed buf))
             (usage-str (agent-shell-hud--get-usage buf))
             (file-rows (mapcar (lambda (f)
                                  (list :label f
                                        :value ""
                                        :icon "dot"))
                                agent-shell-hud--files-touched))
             (rows (append
                    (list
                     (list :label agent-name
                           :value ""
                           :status agent-shell-hud--status
                           :icon "agent")
                     (list :label "Project"
                           :value proj-name
                           :icon "project")
                     (list :label "Action"
                           :value agent-shell-hud--last-action
                           :status agent-shell-hud--status
                           :icon "changes")
                     (list :label "Elapsed"
                           :value elapsed-str
                           :icon "clock")
                     (list :label "Files"
                           :value files-str
                           :icon "changes"))
                    file-rows
                    (list
                     (list :label "Usage"
                           :value usage-str
                           :icon "lsp"))))
             (section-data
              (list
               :title "Agent"
               :priority 30
               :rows rows)))
        (workspace-hud-set-section 'agent-shell section-data)))))

(defun agent-shell-hud--on-event (event)
  "Process the incoming agent-shell EVENT and trigger HUD pushes."
  (let* ((ev-type (map-elt event :event))
         (data (map-elt event :data))
         (buf (current-buffer)))
    (pcase ev-type
      ((or 'init-started 'session-list 'session-prompt)
       (setq-local agent-shell-hud--status "busy")
       (setq-local agent-shell-hud--last-action "Initializing"))
      
      ('init-finished
       (setq-local agent-shell-hud--status "ok")
       (setq-local agent-shell-hud--last-action "Ready"))
      
      ('prompt-ready
       (setq-local agent-shell-hud--status "ok")
       (setq-local agent-shell-hud--last-action "Ready")
       (setq-local agent-shell-hud--files-touched nil)
       (agent-shell-hud--stop-elapsed-timer buf)
       (setq-local agent-shell-hud--turn-start-time nil))
      
      ('tool-call-update
       (unless agent-shell-hud--turn-start-time
         (setq-local agent-shell-hud--turn-start-time (current-time))
         (agent-shell-hud--start-elapsed-timer buf))
       (let* ((tool-call (map-elt data :tool-call))
              (kind (map-elt tool-call :kind))
              (status (map-elt tool-call :status))
              (file-path (agent-shell-hud--extract-file tool-call)))
         (agent-shell-hud--add-touched-file file-path)
         (setq-local agent-shell-hud--status "busy")
         (setq-local agent-shell-hud--last-action
                     (cond
                      ((string= status "running") (format "Calling %s" kind))
                      ((string= status "finished") (format "Finished %s" kind))
                      (t (format "Using %s" kind))))))
      
      ('file-write
       (let ((raw-path (map-elt data :path)))
         (agent-shell-hud--add-touched-file raw-path)
         (setq-local agent-shell-hud--status "busy")
         (setq-local agent-shell-hud--last-action (format "Wrote %s" (file-name-nondirectory raw-path)))))
      
      ('permission-request
       (setq-local agent-shell-hud--status "warn")
       (setq-local agent-shell-hud--last-action "Needs approval"))
      
      ('permission-response
       (setq-local agent-shell-hud--status "busy")
       (setq-local agent-shell-hud--last-action "Processing"))
      
      ('turn-complete
       (setq-local agent-shell-hud--status "ok")
       (setq-local agent-shell-hud--last-action "Turn complete")
       (agent-shell-hud--stop-elapsed-timer buf)
       (setq-local agent-shell-hud--turn-start-time nil))
      
      ('error
       (let* ((msg (map-elt data :message))
              (clean-msg (replace-regexp-in-string "[ \t\r\n]+" " " (or msg "Error occurred")))
              (trimmed (replace-regexp-in-string "\\`[ \t\n\r]+\\|[ \t\n\r]+\\'" "" clean-msg)))
         (setq-local agent-shell-hud--status "error")
         (setq-local agent-shell-hud--last-action trimmed)))
      
      ('clean-up
       (agent-shell-hud--teardown-buffer buf)))
    
    (agent-shell-hud--push-status buf)))

(defun agent-shell-hud--find-relevant-buffer ()
  "Find the most relevant agent-shell buffer for the current context."
  (let* ((target-buf (and (fboundp 'workspace-hud--target-buffer)
                          (workspace-hud--target-buffer)))
         (buffers (and (fboundp 'agent-shell-buffers)
                       (agent-shell-buffers)))
         (current-root (and target-buf
                            (fboundp 'workspace-hud--repo-root)
                            (with-current-buffer target-buf
                              (workspace-hud--repo-root)))))
    (or
     ;; 1. Target buffer itself is agent-shell or viewport
     (cl-find-if (lambda (buf)
                   (or (eq buf target-buf)
                       (and (buffer-live-p target-buf)
                            (with-current-buffer target-buf
                              (and (or (derived-mode-p 'agent-shell-viewport-view-mode)
                                       (derived-mode-p 'agent-shell-viewport-edit-mode))
                                   (fboundp 'agent-shell-viewport--shell-buffer)
                                   (eq buf (agent-shell-viewport--shell-buffer target-buf)))))))
                 buffers)
     ;; 2. Match active shell buffer root to current repository root
     (and current-root
          (cl-find-if (lambda (buf)
                        (let ((buf-root (ignore-errors (with-current-buffer buf (agent-shell-cwd)))))
                          (and buf-root (string= (directory-file-name buf-root)
                                                 (directory-file-name current-root)))))
                      buffers))
     ;; 3. Fallback to first recent buffer
     (car buffers))))

(defvar agent-shell-hud-mode)

(defun agent-shell-hud--on-buffer-change (&rest _)
  "Triggered when the window buffer or selection changes.
This keeps the HUD up-to-date with the active session."
  (when agent-shell-hud-mode
    (when-let ((relevant-buf (agent-shell-hud--find-relevant-buffer)))
      (agent-shell-hud--push-status relevant-buf))))

;; ---------------------------------------------------------------------------
;; Setup & Buffer Lifecycle
;; ---------------------------------------------------------------------------

(defun agent-shell-hud--setup-buffer (buffer)
  "Register event subscription and state tracking on agent-shell BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local agent-shell-hud--files-touched nil)
      (setq-local agent-shell-hud--last-action "Ready")
      (setq-local agent-shell-hud--status "ok")
      (let ((token (agent-shell-subscribe-to
                    :shell-buffer buffer
                    :on-event #'agent-shell-hud--on-event)))
        (setq-local agent-shell-hud--subscription-token token)
        (message "agent-shell-hud: active subscription on %s" (buffer-name buffer))
        (agent-shell-hud--push-status buffer)))))

(defun agent-shell-hud--teardown-buffer (buffer)
  "Remove event subscription and clean up HUD section for BUFFER."
  (when (buffer-live-p buffer)
    (agent-shell-hud--stop-elapsed-timer buffer)
    (with-current-buffer buffer
      (when agent-shell-hud--subscription-token
        (ignore-errors
          (agent-shell-unsubscribe :subscription agent-shell-hud--subscription-token))
        (setq-local agent-shell-hud--subscription-token nil))))
  ;; If there are other live agent-shell buffers, update the HUD with the most relevant one
  (if-let ((relevant-buf (agent-shell-hud--find-relevant-buffer)))
      (agent-shell-hud--push-status relevant-buf)
    (workspace-hud-remove-section 'agent-shell)))

(defun agent-shell-hud--on-shell-init ()
  "Hook helper that runs when an agent shell buffer is initialized."
  (agent-shell-hud--setup-buffer (current-buffer)))

;; ---------------------------------------------------------------------------
;; Global Minor Mode
;; ---------------------------------------------------------------------------

;;;###autoload
(define-minor-mode agent-shell-hud-mode
  "Automatically push agent-shell status metrics into the workspace HUD."
  :global t
  :group 'agent-shell-hud
  (if agent-shell-hud-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-shell-hud--on-shell-init)
        (add-hook 'window-buffer-change-functions #'agent-shell-hud--on-buffer-change)
        (add-hook 'window-selection-change-functions #'agent-shell-hud--on-buffer-change)
        ;; Wire up any active/existing shell buffers immediately
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (derived-mode-p 'agent-shell-mode)
              (agent-shell-hud--setup-buffer buf))))
        ;; Push the initial state for the most relevant buffer if any
        (when-let ((relevant-buf (agent-shell-hud--find-relevant-buffer)))
          (agent-shell-hud--push-status relevant-buf)))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-hud--on-shell-init)
    (remove-hook 'window-buffer-change-functions #'agent-shell-hud--on-buffer-change)
    (remove-hook 'window-selection-change-functions #'agent-shell-hud--on-buffer-change)
    ;; Teardown subscriptions in all buffer instances
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'agent-shell-mode)
          (agent-shell-hud--teardown-buffer buf))))
    (workspace-hud-remove-section 'agent-shell)))

(provide 'agent-shell-hud)
;;; agent-shell-hud.el ends here
