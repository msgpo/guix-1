;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Federico Beffa <beffa@fbengineering.ch>
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

(define-module (guix build-system haskell)
  #:use-module (guix store)
  #:use-module (guix utils)
  #:use-module (guix packages)
  #:use-module (guix derivations)
  #:use-module (guix build-system)
  #:use-module (guix build-system gnu)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-26)
  #:export (haskell-build
            haskell-build-system))

;; Commentary:
;;
;; Standard build procedure for Haskell packages using 'Setup.hs'.  This is
;; implemented as an extension of 'gnu-build-system'.
;;
;; Code:

(define (default-haskell)
  "Return the default Haskell package."
  ;; Lazily resolve the binding to avoid a circular dependency.
  (let ((haskell (resolve-interface '(gnu packages haskell))))
    (module-ref haskell 'ghc)))

(define* (lower name
                #:key source inputs native-inputs outputs system target
                (haskell (default-haskell))
                #:allow-other-keys
                #:rest arguments)
  "Return a bag for NAME."
  (define private-keywords
    '(#:target #:haskell #:inputs #:native-inputs))

  (and (not target)                               ;XXX: no cross-compilation
       (bag
         (name name)
         (system system)
         (host-inputs `(,@(if source
                              `(("source" ,source))
                              '())
                        ,@inputs

                        ;; Keep the standard inputs of 'gnu-build-system'.
                        ,@(standard-packages)))
         (build-inputs `(("haskell" ,haskell)
                         ,@native-inputs))
         (outputs outputs)
         (build haskell-build)
         (arguments (strip-keyword-arguments private-keywords arguments)))))

(define* (haskell-build store name inputs
                        #:key source
                        (haddock? #t)
                        (haddock-flags ''())
                        (tests? #t)
                        (test-target "test")
                        (configure-flags ''())
                        (phases '(@ (guix build haskell-build-system)
                                    %standard-phases))
                        (outputs '("out"))
                        (search-paths '())
                        (system (%current-system))
                        (guile #f)
                        (imported-modules '((guix build haskell-build-system)
                                            (guix build gnu-build-system)
                                            (guix build utils)))
                        (modules '((guix build haskell-build-system)
                                   (guix build utils))))
  "Build SOURCE using HASKELL, and with INPUTS.  This assumes that SOURCE
provides a 'Setup.hs' file as its build system."
  (define builder
    `(begin
       (use-modules ,@modules)
       (haskell-build #:name ,name
                      #:source ,(match (assoc-ref inputs "source")
                                  (((? derivation? source))
                                   (derivation->output-path source))
                                  ((source)
                                   source)
                                  (source
                                   source))
                      #:configure-flags ,configure-flags
                      #:haddock-flags ,haddock-flags
                      #:system ,system
                      #:test-target ,test-target
                      #:tests? ,tests?
                      #:haddock? ,haddock?
                      #:phases ,phases
                      #:outputs %outputs
                      #:search-paths ',(map search-path-specification->sexp
                                            search-paths)
                      #:inputs %build-inputs)))

  (define guile-for-build
    (match guile
      ((? package?)
       (package-derivation store guile system #:graft? #f))
      (#f                                         ; the default
       (let* ((distro (resolve-interface '(gnu packages commencement)))
              (guile  (module-ref distro 'guile-final)))
         (package-derivation store guile system #:graft? #f)))))

  (build-expression->derivation store name builder
                                #:inputs inputs
                                #:system system
                                #:modules imported-modules
                                #:outputs outputs
                                #:guile-for-build guile-for-build))

(define haskell-build-system
  (build-system
    (name 'haskell)
    (description "The standard Haskell build system")
    (lower lower)))

;;; haskell.scm ends here