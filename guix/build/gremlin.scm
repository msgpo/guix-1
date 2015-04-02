;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix build gremlin)
  #:use-module (guix elf)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:export (elf-dynamic-info
            elf-dynamic-info?
            elf-dynamic-info-sopath
            elf-dynamic-info-needed
            elf-dynamic-info-rpath
            elf-dynamic-info-runpath

            validate-needed-in-runpath))

;;; Commentary:
;;;
;;; A gremlin is sort-of like an elf, you know, and this module provides tools
;;; to deal with dynamic-link information from ELF files.
;;;
;;; Code:

(define (dynamic-link-segment elf)
  "Return the 'PT_DYNAMIC' segment of ELF--i.e., the segment that contains
dynamic linking information."
  (find (lambda (segment)
          (= (elf-segment-type segment) PT_DYNAMIC))
        (elf-segments elf)))

(define (word-reader size byte-order)
  "Return a procedure to read a word of SIZE bytes according to BYTE-ORDER."
  (case size
    ((8)
     (lambda (bv index)
       (bytevector-u64-ref bv index byte-order)))
    ((4)
     (lambda (bv index)
       (bytevector-u32-ref bv index byte-order)))))


;; Dynamic entry:
;;
;; typedef struct
;; {
;;   Elf64_Sxword       d_tag;   /* Dynamic entry type */
;;   union
;;     {
;;       Elf64_Xword d_val;      /* Integer value */
;;       Elf64_Addr d_ptr;       /* Address value */
;;     } d_un;
;; } Elf64_Dyn;

(define (raw-dynamic-entries elf segment)
  "Return as a list of type/value pairs all the dynamic entries found in
SEGMENT, the 'PT_DYNAMIC' segment of ELF.  In the result, each car is a DT_
value, and the interpretation of the cdr depends on the type."
  (define start
    (elf-segment-offset segment))
  (define bytes
    (elf-bytes elf))
  (define word-size
    (elf-word-size elf))
  (define byte-order
    (elf-byte-order elf))
  (define read-word
    (word-reader word-size byte-order))

  (let loop ((offset 0)
             (result '()))
    (if (>= offset (elf-segment-memsz segment))
        (reverse result)
        (let ((type  (read-word bytes (+ start offset)))
              (value (read-word bytes (+ start offset word-size))))
          (if (= type DT_NULL)                    ;finished?
              (reverse result)
              (loop (+ offset (* 2 word-size))
                    (alist-cons type value result)))))))

(define (vma->offset elf vma)
  "Convert VMA, a virtual memory address, to an offset within ELF.

Do that by looking at the loadable program segment (PT_LOAD) of ELF that
contains VMA and by taking into account that segment's virtual address and
offset."
  ;; See 'offset_from_vma' in Binutils.
  (define loads
    (filter (lambda (segment)
              (= (elf-segment-type segment) PT_LOAD))
            (elf-segments elf)))

  (let ((load (find (lambda (segment)
                      (let ((vaddr (elf-segment-vaddr segment)))
                        (and (>= vma vaddr)
                             (< vma (+ (elf-segment-memsz segment)
                                       vaddr)))))
                    loads)))
    (+ (- vma (elf-segment-vaddr load))
       (elf-segment-offset load))))

(define (dynamic-entries elf segment)
  "Return all the dynamic entries found in SEGMENT, the 'PT_DYNAMIC' segment
of ELF, as a list of type/value pairs.  The type is a DT_ value, and the value
may be a string or an integer depending on the entry type (for instance, the
value of DT_NEEDED entries is a string.)"
  (define entries
    (raw-dynamic-entries elf segment))

  (define string-table-offset
    (any (match-lambda
            ((type . value)
             (and (= type DT_STRTAB) value))
            (_ #f))
         entries))

  (define (interpret-dynamic-entry type value)
    (cond ((memv type (list DT_NEEDED DT_SONAME DT_RPATH DT_RUNPATH))
           (if string-table-offset
               (pointer->string
                (bytevector->pointer (elf-bytes elf)
                                     (vma->offset
                                      elf
                                      (+ string-table-offset value))))
               value))
          (else
           value)))

  (map (match-lambda
         ((type . value)
          (cons type (interpret-dynamic-entry type value))))
       entries))


;;;
;;; High-level interface.
;;;

(define-record-type <elf-dynamic-info>
  (%elf-dynamic-info soname needed rpath runpath)
  elf-dynamic-info?
  (soname    elf-dynamic-info-soname)
  (needed    elf-dynamic-info-needed)
  (rpath     elf-dynamic-info-rpath)
  (runpath   elf-dynamic-info-runpath))

(define search-path->list
  (let ((not-colon (char-set-complement (char-set #\:))))
    (lambda (str)
      "Split STR on ':' characters."
      (string-tokenize str not-colon))))

(define (elf-dynamic-info elf)
  "Return dynamic-link information for ELF as an <elf-dynamic-info> object, or
#f if ELF lacks dynamic-link information."
  (match (dynamic-link-segment elf)
    (#f #f)
    ((? elf-segment? dynamic)
     (let ((entries (dynamic-entries elf dynamic)))
       (%elf-dynamic-info (assv-ref entries DT_SONAME)
                          (filter-map (match-lambda
                                        ((type . value)
                                         (and (= type DT_NEEDED) value))
                                        (_ #f))
                                      entries)
                          (or (and=> (assv-ref entries DT_RPATH)
                                     search-path->list)
                              '())
                          (or (and=> (assv-ref entries DT_RUNPATH)
                                     search-path->list)
                              '()))))))

(define %libc-libraries
  ;; List of libraries as of glibc 2.21 (there are more but those are
  ;; typically mean to be LD_PRELOADed and thus do not appear as NEEDED.)
  '("libanl.so"
    "libcrypt.so"
    "libc.so"
    "libdl.so"
    "libm.so"
    "libpthread.so"
    "libresolv.so"
    "librt.so"
    "libutil.so"))

(define (libc-library? lib)
  "Return #t if LIB is one of the libraries shipped with the GNU C Library."
  (find (lambda (libc-lib)
          (string-prefix? libc-lib lib))
        %libc-libraries))

(define* (validate-needed-in-runpath file
                                     #:key (always-found? libc-library?))
  "Return #t if all the libraries listed as FILE's 'DT_NEEDED' entries are
present in its RUNPATH, or if FILE lacks dynamic-link information.  Return #f
otherwise.  Libraries whose name matches ALWAYS-FOUND? are considered to be
always available."
  (let* ((elf     (call-with-input-file file
                    (compose parse-elf get-bytevector-all)))
         (dyninfo (elf-dynamic-info elf)))
    (when dyninfo
      (let* ((runpath   (elf-dynamic-info-runpath dyninfo))
             (needed    (remove always-found?
                                (elf-dynamic-info-needed dyninfo)))
             (not-found (remove (cut search-path runpath <>)
                                needed)))
        (for-each (lambda (lib)
                    (format (current-error-port)
                            "error: '~a' depends on '~a', which cannot \
be found in RUNPATH ~s~%"
                            file lib runpath))
                  not-found)
        ;; (when (null? not-found)
        ;;   (format (current-error-port) "~a is OK~%" file))
        (null? not-found)))))

;;; gremlin.scm ends here