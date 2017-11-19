;;; unrepl-loop.el --- UNREPL EDN messages processing -*- lexical-binding: t; -*-
;;
;; Filename: unrepl-loop.el
;; Author: Daniel Barreto <daniel@barreto.tech>
;; Maintainer: Daniel Barreto <daniel@barreto.tech>
;; Copyright (C) 2017 Daniel Barreto
;; Created: Sat Nov 11 20:07:16 2017 (+0100)
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; Processing of UNREPL EDN messages.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'arc-mode)
(require 'parseclj)
(require 'treepy)

(require 'unrepl-mode)
(require 'unrepl-project)
(require 'unrepl-repl)
(require 'unrepl-util)


(defvar-local unrepl-loop-process-type nil
  "Type of process.
This local variable is meant to be set in conn-pool processes' buffers so
that they are easily distinguishable.")

(defvar-local unrepl-loop-process-dispatcher nil
  "The EDN message dispatcher function for a process buffer.")

(defvar-local unrepl-loop-greeted-p nil
  "Predicate that defines if the client for the current buffer has been greeted already.")


(defun unrepl-loop--announce-greeting-p (process)
  "Decide whether or not to announce this PROCESS greetings."
  (with-current-buffer (process-buffer process)
    (eql unrepl-loop-process-type :client)))


(defun unrepl-loop--send (conn-id proc-type str &optional no-line-break)
  "Send input STR to PROC-TYPE of CONN-ID.
PROC-TYPE is a keyword, either `:client', `:aux', or `:side-loader'.
By default, this function will add a new line after STR.  NO-LINE-BREAK
overrides this behavior."
  (let* ((project (unrepl-projects-get conn-id))
         (proc (unrepl-project-conn-pool-get-process project proc-type)))
    (process-send-string proc (concat str (unless no-line-break "\n")))
    str))


(defun unrepl-loop--destructure-message-ast (msg-node)
  "Traverse MSG-NODE and return its UNREPL tag, payload and group-id.
Tag is returned as a keyword.
Payload is returned as a parseclj AST node.
Group-id is returned as an integer."
  (let* ((zp (unrepl-ast-zip msg-node))
         (tag (-> zp
                  (treepy-down)
                  (treepy-node)
                  (parseclj-ast-value)))
         (payload (-> zp
                      (treepy-down)
                      (treepy-right)
                      (treepy-node)))
         (group-id (-> zp
                       (treepy-down)
                       (treepy-right)
                       (treepy-right)
                       (treepy-node)
                       (parseclj-ast-value))))
    (list tag payload group-id)))


(declare-function unrepl-process-conn-id "unrepl")
(defun unrepl-loop-handle-proc-message (process output)
  "Decode OUTPUT's EDN messages from PROCESS, and dispatch accordingly."
  (let ((proc-buf (process-buffer process)))
    (with-current-buffer proc-buf
      (unless unrepl-loop-greeted-p
        (when-let (hello-match (string-match-p "\\[:unrepl.*/hello" output))
          (setq output (substring output hello-match))
          (setq-local unrepl-loop-greeted-p t)
          (when (unrepl-loop--announce-greeting-p process)
            (message "UNREPL says hi!"))))
      (when unrepl-loop-greeted-p
        (goto-char (point-max))
        (save-excursion (insert output))

        ;; There can be several EDN messages in OUTPUT, so we iterate over them.
        (mapcar (lambda (msg-ast-node)
                  (apply unrepl-loop-process-dispatcher
                         (unrepl-process-conn-id process)
                         (unrepl-loop--destructure-message-ast msg-ast-node)))
                (parseclj-ast-children (parseclj-parse-clojure)))))))



;; Client Process
;; =============================================================================

(defun unrepl-client-send (str &optional eval-out-callback)
  "Send input STR to UNREPL client connection.
EVAL-OUT-CALLBACK is a function that takes the evaluation payload and
displays it in any given way.
Connection to sent the input to is inferred
from `unrepl-conn-id'."
  (prog1 (unrepl-loop--send unrepl-conn-id :client str)
    (unrepl-project-pending-eval-add unrepl-conn-id
                                     :status :sent
                                     :eval-callback eval-out-callback)))


(defun unrepl-loop-client-dispatcher (conn-id tag payload &optional group-id)
  "Dispatch an UNREPL message to an `unrepl-loop--client-*' message handler.
CONN-ID is provided to client message handlers so they know which
project/repl to modify.
TAG is the UNREPL tag, and it's used to select the handler function for the
message.
PAYLOAD is a parseclj AST node of the message's payload.
GROUP-ID is a number."
  (pcase tag
    (:unrepl/hello (unrepl-loop--client-hello conn-id payload))
    (:prompt (unrepl-loop--client-prompt conn-id payload))
    (:read (unrepl-loop--client-read conn-id payload group-id))
    (:started-eval (unrepl-loop--client-started-eval conn-id payload group-id))
    (:eval (unrepl-loop--client-eval conn-id payload group-id))
    (:out (unrepl-loop--client-out conn-id payload group-id))
    (:exception (unrepl-loop--client-placeholder-handler conn-id payload group-id))
    (_ (error (format "[client] Unrecognized message: %S" tag)))))

;; Message Processing
;; ------------------

(defmacro unrepl-loop--unpack-payload (vars &rest body)
  "Take VARS out of `payload' and make them available in BODY scope.
This macro assumes the existence of a `payload' variable in scope, if there
isn't, an error will be raised.

VARS is a list of symbols that should have corresponding keywords in (an
already available) `payload' variable.  For each symbol in vars, a
corresponding variable will be created and it the value of =(gethash <var
as a keyword> payload)= and will be added to the local scope in which BODY
gets executed."
  (declare (indent 1))
  `(let (,@(mapcar
            (lambda (v)
              `(,v (unrepl-ast-map-elt payload ,(intern-soft (format ":%s" v)))))
            vars))
     ,@body))


(declare-function unrepl-create-connection-process "unrepl")
(defun unrepl-loop--client-hello (conn-id payload)
  "Handle a `:unrepl/hello' message transmitted through CONN-ID.
It processes the PAYLOAD to init the corresponding REPL and subsequent
evaluation of inputs."
  (unrepl-loop--unpack-payload
      (actions)
    (unrepl-repl-connected conn-id)                   ;; Start REPL
    (unrepl-project-set-in conn-id :actions actions)  ;; Store global actions
    ;; And start aux connections
    (let* ((host-port (unrepl-conn-host-port conn-id))
           (host (car host-port))
           (port (cdr host-port))
           (start-aux-msg (unrepl-command-template (unrepl-ast-map-elt actions :start-aux)))
           (start-sl-msg (unrepl-command-template (unrepl-ast-map-elt actions :unrepl.jvm/start-side-loader))))
      (unrepl-project-conn-pool-set-in
       conn-id
       :aux (unrepl-create-connection-process :aux host port
                                              start-aux-msg
                                              #'unrepl-loop-aux-handler)
       :side-loader (unrepl-create-connection-process :side-loader host port
                                                      start-sl-msg
                                                      #'unrepl-loop-side-loader-handler)))))


(defun unrepl-loop--client-prompt (conn-id payload)
  "Handle a `:prompt' message transmitted through CONN-ID.
PAYLOAD is the UNREPL payload for `:prompt' as a AST NODE."
  (unrepl-project-set-in conn-id
                         :namespace (-> payload
                                        (unrepl-ast-map-elt 'clojure.core/*ns*)  ;; tagged element
                                        (parseclj-ast-children)
                                        (car)                                    ;; actual ns symbol
                                        (parseclj-ast-value)))
  (if-let (pending-eval (unrepl-project-pending-evals-shift conn-id))
      (when (unrepl-project-pending-eval-entry-history-idx pending-eval)
        (unrepl-repl-prompt conn-id))
    (unrepl-repl-prompt conn-id)))


(defun unrepl-loop--client-read (conn-id _payload group-id)
  "Handle a `:read' message transmitted through CONN-ID.
PAYLOAD is the UNREPL payload for `:read' as a hash table.
GROUP-ID is an integer as described by UNREPL's documentation."
  (let ((history-assoc (unrepl-repl-input-history-assoc conn-id group-id)))
    ;; `history-assoc' is either nil or a tuple that contains
    ;; `:repl-history-idx' as its first element and a history entry id as its
    ;; second element.  For more information, read its documentation.
    (apply #'unrepl-project-pending-eval-update conn-id
           :status :read
           :group-id group-id
           :actions nil
           history-assoc)))


(defun unrepl-loop--client-started-eval (conn-id payload group-id)
  "Handle a `:started-eval' message transmitted through CONN-ID.
PAYLOAD is the UNREPL payload for `:started-eval' as a hash table.
GROUP-ID is an integer as described by UNREPL's documentation."
  (unrepl-loop--unpack-payload
      (actions)
    (unrepl-project-pending-eval-update conn-id
                                        :status :started-eval
                                        :group-id group-id
                                        :actions actions)))


(defun unrepl-loop--client-eval (conn-id payload _group-id)
  "Handle a `:eval' message transmitted through CONN-ID.
PAYLOAD is the UNREPL payload for `:eval' as a hash table.
GROUP-ID is an integer as described by UNREPL's documentation.

This function will see if there's an evaluation display callback function,
and it will use it to show the result.  If not, it will try to determine
where did this evaluation come from (REPL buffer, `unrepl-eval-last-sexp'
command, etc), and will call a different function to display the result
accordingly."
  (unrepl-project-pending-eval-update conn-id
                                      :status :eval)
  ;; Display the evaluation payload somewhere...
  (let ((eval-result (parseclj-unparse-clojure-to-string payload)))
    (if-let (eval-callback (unrepl-project-pending-eval-callback conn-id))
        (funcall eval-callback eval-result)
      (message "%s" eval-result))))


(defun unrepl-loop--client-out (conn-id payload group-id)
  "Handle a `:out' message transmitted through CONN-ID.
PAYLOAD is the UNREPL payload for `:eval' as a hash table.
GROUP-ID is an integer as described by UNREPL's documentation."
  (unrepl-repl-insert-out conn-id group-id
                          (parseclj-ast-value payload)))


(defun unrepl-loop--client-placeholder-handler (conn-id payload group-id)
  "Placeholder handler CONN-ID PAYLOAD GROUP-ID."
  (unrepl-repl-insert-out conn-id group-id
                          (format "%s\n" (parseclj-unparse-clojure-to-string payload))))



;; Aux Connection Process
;; =============================================================================

(defun unrepl-aux-send (str)
  "Send input STR to UNREPL aux connection.
Connection to sent the input to is inferred from `unrepl-conn-id'."
  (unrepl-loop--send unrepl-conn-id :aux str))


(defun unrepl-loop-aux-handler (&rest _args)
  "Dispatch MSG to an `unrepl-loop--aux-*' message handler.
CONN-ID is provided to the handlers so they know which project/repl they
will be affecting."
  )  ;; All are noops, for now.



;; Side Loader Process
;; =============================================================================

(defun unrepl-side-loader-send (str)
  "Send input STR to UNREPL side loader connection.
Connection to sent the input to is inferred from `unrepl-conn-id'."
  (unrepl-loop--send unrepl-conn-id :side-loader str))


(defun unrepl-loop-side-loader-handler (conn-id tag payload &rest _extra)
  "Dispatch message to an `unrepl-loop--side-loader-*' message handler.
CONN-ID is provided to side-loader message handlers so they know which
project/repl to modify.
TAG is the UNREPL tag for side-loading, expected to be either `:class' or
`:resource'.
PAYLOAD is a parseclj AST node of the message's payload, which should be a
string."
  (unless (memq tag '(:unrepl.jvm.side-loader/hello :class :resource))
    (error (format "[side-loader] Unrecognized message: %S" tag)))
  (unless (eql tag :unrepl.jvm.side-loader/hello)
    (let* ((payload-val (parseclj-ast-value payload))
           (file-path (if (eql tag :class)
                          (format "%s.class"
                                  (replace-regexp-in-string "\\." "/" payload-val))
                        payload-val)))
      (unrepl-loop--side-loader-resource conn-id file-path))))


(defun unrepl-loop--side-loader-find-file (file-path classpath)
  "Try to find FILE-PATH in CLASSPATH.
CLASSPATH should be a list of paths.  If nothing is found, return nil.
Return the file contents encoded as a base64 string."
  (when-let (path (car classpath))
    (let ((encoded-buffer (lambda ()
                            (encode-coding-region (point-min) (point-max) 'utf-8)
                            (base64-encode-region (point-min) (point-max) t)
                            (format "%S"
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (cond
       ;; path as a directory
       ((file-directory-p path)
        (let ((file-path-complete (concat (file-name-as-directory path)
                                          file-path)))
          (if (file-exists-p file-path-complete)
              (with-temp-buffer
                (insert-file-contents file-path-complete)
                (funcall encoded-buffer))
            (unrepl-loop--side-loader-find-file file-path (cdr classpath)))))
       ;; path as a file (assumed to be jar/zip)
       (t
        (with-temp-buffer
          (condition-case err
              (progn
                (let ((message-log-max nil)
                      (inhibit-message t))
                  (archive-zip-extract path file-path))
                (if (> (buffer-size) 0)
                    (funcall encoded-buffer)
                  (unrepl-loop--side-loader-find-file file-path (cdr classpath))))
            (error
             (ding (message "%S" err))
             (unrepl-loop--side-loader-find-file file-path (cdr classpath))))))))))


(defun unrepl-loop--side-loader-resource (conn-id file-path)
  "Find a FILE-PATH in CONN-ID's classpath.
Classpath is taken from CONN-ID'S project.
The actual file is then sent back to the side-loader as a base64 string.
If FILE-PATH cannot be found, send nil to side-loader."
  (let ((classpath (-> conn-id
                       (unrepl-projects-get)
                       (unrepl-project-classpath))))
    (let ((base64-contents (unrepl-loop--side-loader-find-file file-path classpath)))
      (unrepl-side-loader-send (or base64-contents "nil")))))

(provide 'unrepl-loop)

;;; unrepl-loop.el ends here
