;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 David Thompson <davet@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix scripts publish)
  #:use-module ((system repl server) #:prefix repl:)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (rnrs io ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-2)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-37)
  #:use-module (web http)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web server)
  #:use-module (web uri)
  #:use-module (guix base32)
  #:use-module (guix base64)
  #:use-module (guix config)
  #:use-module (guix derivations)
  #:use-module (guix hash)
  #:use-module (guix pki)
  #:use-module (guix pk-crypto)
  #:use-module (guix store)
  #:use-module (guix serialization)
  #:use-module (guix ui)
  #:export (guix-publish))

(define (show-help)
  (format #t (_ "Usage: guix publish [OPTION]...
Publish ~a over HTTP.\n") %store-directory)
  (display (_ "
  -p, --port=PORT        listen on PORT"))
  (display (_ "
  -r, --repl[=PORT]      spawn REPL server on PORT"))
  (newline)
  (display (_ "
  -h, --help             display this help and exit"))
  (display (_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  (list (option '(#\h "help") #f #f
                (lambda _
                  (show-help)
                  (exit 0)))
        (option '(#\V "version") #f #f
                (lambda _
                  (show-version-and-exit "guix publish")))
        (option '(#\p "port") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'port (string->number* arg) result)))
        (option '(#\r "repl") #f #t
                (lambda (opt name arg result)
                  ;; If port unspecified, use default Guile REPL port.
                  (let ((port (and arg (string->number* arg))))
                    (alist-cons 'repl (or port 37146) result))))))

(define %default-options
  '((port . 8080)
    (repl . #f)))

(define (lazy-read-file-sexp file)
  "Return a promise to read the canonical sexp from FILE."
  (delay
    (call-with-input-file file
      (compose string->canonical-sexp
               get-string-all))))

(define %private-key
  (lazy-read-file-sexp %private-key-file))

(define %public-key
  (lazy-read-file-sexp %public-key-file))

(define %nix-cache-info
  `(("StoreDir" . ,%store-directory)
    ("WantMassQuery" . 0)
    ("Priority" . 100)))

(define (load-derivation file)
  "Read the derivation from FILE."
  (call-with-input-file file read-derivation))

(define (signed-string s)
  "Sign the hash of the string S with the daemon's key."
  (let* ((public-key (force %public-key))
         (hash (bytevector->hash-data (sha256 (string->utf8 s))
                                      #:key-type (key-type public-key))))
    (signature-sexp hash (force %private-key) public-key)))

(define base64-encode-string
  (compose base64-encode string->utf8))

(define (narinfo-string store-path path-info key)
  "Generate a narinfo key/value string for STORE-PATH using the details in
PATH-INFO.  The narinfo is signed with KEY."
  (let* ((url        (string-append "nar/" (basename store-path)))
         (hash       (bytevector->base32-string
                      (path-info-hash path-info)))
         (size       (path-info-nar-size path-info))
         (references (string-join
                      (map basename (path-info-references path-info))
                      " "))
         (deriver (path-info-deriver path-info))
         (base-info  (format #f
                             "StorePath: ~a
URL: ~a
Compression: none
NarHash: sha256:~a
NarSize: ~d
References: ~a~%"
                             store-path url hash size references))
         ;; Do not render a "Deriver" or "System" line if we are rendering
         ;; info for a derivation.
         (info (if (string-null? deriver)
                   base-info
                   (let ((drv (load-derivation deriver)))
                     (format #f "~aSystem: ~a~%Deriver: ~a~%"
                             base-info (derivation-system drv)
                             (basename deriver)))))
         (signature  (base64-encode-string
                      (canonical-sexp->string (signed-string info)))))
    (format #f "~aSignature: 1;~a;~a~%" info (gethostname) signature)))

(define (not-found request)
  "Render 404 response for REQUEST."
  (values (build-response #:code 404)
          (string-append "Resource not found: "
                         (uri-path (request-uri request)))))

(define (render-nix-cache-info)
  "Render server information."
  (values '((content-type . (text/plain)))
          (lambda (port)
            (for-each (match-lambda
                       ((key . value)
                        (format port "~a: ~a~%" key value)))
                      %nix-cache-info))))

(define (render-narinfo store request hash)
  "Render metadata for the store path corresponding to HASH."
  (let* ((store-path (hash-part->path store hash))
         (path-info (and (not (string-null? store-path))
                         (query-path-info store store-path))))
    (if path-info
        (values '((content-type . (application/x-nix-narinfo)))
                (cut display
                     (narinfo-string store-path path-info (force %private-key))
                     <>))
        (not-found request))))

(define (render-nar request store-item)
  "Render archive of the store path corresponding to STORE-ITEM."
  (let ((store-path (string-append %store-directory "/" store-item)))
    ;; The ISO-8859-1 charset *must* be used otherwise HTTP clients will
    ;; interpret the byte stream as UTF-8 and arbitrarily change invalid byte
    ;; sequences.
    (if (file-exists? store-path)
        (values '((content-type . (application/x-nix-archive
                                   (charset . "ISO-8859-1"))))
                (lambda (port)
                  (write-file store-path port)))
        (not-found request))))

(define extract-narinfo-hash
  (let ((regexp (make-regexp "^([a-df-np-sv-z0-9]{32}).narinfo$")))
    (lambda (str)
      "Return the hash within the narinfo resource string STR, or false if STR
is invalid."
      (and=> (regexp-exec regexp str)
             (cut match:substring <> 1)))))

(define (get-request? request)
  "Return #t if REQUEST uses the GET method."
  (eq? (request-method request) 'GET))

(define (request-path-components request)
  "Split the URI path of REQUEST into a list of component strings.  For
example: \"/foo/bar\" yields '(\"foo\" \"bar\")."
  (split-and-decode-uri-path (uri-path (request-uri request))))

(define (make-request-handler store)
  (lambda (request body)
    (format #t "~a ~a~%"
            (request-method request)
            (uri-path (request-uri request)))
    (if (get-request? request) ; reject POST, PUT, etc.
        (match (request-path-components request)
          ;; /nix-cache-info
          (("nix-cache-info")
           (render-nix-cache-info))
          ;; /<hash>.narinfo
          (((= extract-narinfo-hash (? string? hash)))
           (render-narinfo store request hash))
          ;; /nar/<store-item>
          (("nar" store-item)
           (render-nar request store-item))
          (_ (not-found request)))
        (not-found request))))

(define (run-publish-server port store)
  (run-server (make-request-handler store)
              'http
              `(#:addr ,INADDR_ANY
                #:port ,port)))

(define (guix-publish . args)
  (with-error-handling
    (let* ((opts (args-fold* args %options
                             (lambda (opt name arg result)
                               (leave (_ "~A: unrecognized option~%") name))
                             (lambda (arg result)
                               (leave (_ "~A: extraneuous argument~%") arg))
                             %default-options))
           (port (assoc-ref opts 'port))
           (repl-port (assoc-ref opts 'repl)))
      (format #t (_ "publishing ~a on port ~d~%") %store-directory port)
      (when repl-port
        (repl:spawn-server (repl:make-tcp-server-socket #:port repl-port)))
      (with-store store
        (run-publish-server (assoc-ref opts 'port) store)))))