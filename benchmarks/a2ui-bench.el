;;; a2ui-bench.el --- Rendering benchmarks for a2ui -*- lexical-binding: t; -*-

;;; Commentary:

;; Run `a2ui-bench-main' in batch from the project root, loading this
;; file through Eldev so vui is on the load path (see DESIGN.md).
;;
;; Renders a templated list of N rows, each a Text and a TextField
;; bound to the row, then measures what a user feels: the first render,
;; and the re-render after typing one character into one row.

;;; Code:

(require 'a2ui)
(require 'benchmark)

(defun a2ui-bench--messages (rows)
  "Return messages for a surface listing ROWS people with a note field."
  (let ((people (vconcat (cl-loop for i below rows
                                  collect (a2ui-obj "name" (format "Person %d" i) "note" "")))))
    (list (a2ui-obj "version" "v0.9"
                    "createSurface" (a2ui-obj "surfaceId" "bench" "catalogId" a2ui-basic-catalog-id))
          (a2ui-json-parse
           "{\"version\":\"v0.9\",\"updateComponents\":{\"surfaceId\":\"bench\",\"components\":[
             {\"id\":\"root\",\"component\":\"List\",\"children\":{\"path\":\"/people\",\"componentId\":\"row\"}},
             {\"id\":\"row\",\"component\":\"Column\",\"children\":[\"name\",\"note\"]},
             {\"id\":\"name\",\"component\":\"Text\",\"text\":{\"path\":\"name\"}},
             {\"id\":\"note\",\"component\":\"TextField\",\"label\":\"Note\",\"value\":{\"path\":\"note\"},
              \"checks\":[{\"condition\":{\"call\":\"length\",\"args\":{\"value\":{\"path\":\"note\"},\"max\":20}},\"message\":\"Too long.\"}]}]}}")
          (a2ui-obj "version" "v0.9"
                    "updateDataModel" (a2ui-obj "surfaceId" "bench" "value" (a2ui-obj "people" people))))))

(defun a2ui-bench--settle (buffer)
  "Wait until BUFFER's vui root has no render pending."
  (let ((root (vui-get-instance buffer)))
    (while (and root (vui-instance-render-timer root))
      (sleep-for 0.001))))

(defun a2ui-bench-run (rows)
  "Benchmark a surface of ROWS rows and print the timings."
  (let* ((a2ui-log-messages nil)
         (session (a2ui-vui-attach (a2ui-session-create :name "bench")))
         (start (float-time)))
    (dolist (m (a2ui-bench--messages rows))
      (a2ui-apply-message session m))
    (let ((buffer (car (a2ui-vui--view session "bench"))))
      (a2ui-bench--settle buffer)
      (let ((first (- (float-time) start))
            (lines (with-current-buffer buffer (count-lines (point-min) (point-max)))))
        (with-current-buffer buffer
          (vui-goto-key (format "note@/people/%d" (/ rows 2)))
          (forward-char 1)
          (let* ((n 10)
                 (elapsed
                  (car (benchmark-run n
                         (insert "x")
                         (a2ui-bench--settle buffer)))))
            (princ (format "%4d rows (%d lines): first render %.0f ms, keystroke %.0f ms\n"
                           rows lines (* 1000 first) (* 1000 (/ elapsed n))))))
        (kill-buffer buffer)))))

(defun a2ui-bench-main ()
  "Run the benchmarks at several sizes."
  (dolist (rows '(50 100 250 500 1000))
    (a2ui-bench-run rows)))

(provide 'a2ui-bench)
;;; a2ui-bench.el ends here
