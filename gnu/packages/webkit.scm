;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Sou Bunnbu <iyzsong@gmail.com>
;;; Copyright © 2015 David Hashe <david.hashe@dhashe.com>
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

(define-module (gnu packages webkit)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system cmake)
  #:use-module (gnu packages bison)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages enchant)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages gnutls)
  #:use-module (gnu packages gperf)
  #:use-module (gnu packages gstreamer)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages icu4c)
  #:use-module (gnu packages image)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages ruby)
  #:use-module (gnu packages video)
  #:use-module (gnu packages xml)
  #:use-module (gnu packages xorg))

(define-public webkitgtk
  (package
    (name "webkitgtk")
    (version "2.8.1")
    (source (origin
              (method url-fetch)
              (uri (string-append "http://www.webkitgtk.org/releases/"
                                  name "-" version ".tar.xz"))
              (sha256
               (base32
                "1zv030ryfwwp57yzlpr9bgpxcmc64izsxk2vsyd4kjhns9cl88bx"))))
    (build-system cmake-build-system)
    (arguments
     '(#:tests? #f ; no tests
       #:build-type "Release" ; turn off debugging symbols to save space
       #:configure-flags (list
                          "-DPORT=GTK"
                          (string-append ; uses lib64 by default
                           "-DLIB_INSTALL_DIR="
                           (assoc-ref %outputs "out") "/lib"))))
    (native-inputs
     `(("bison" ,bison)
       ("gettext" ,gnu-gettext)
       ("glib:bin" ,glib "bin") ; for glib-mkenums, etc.
       ("gobject-introspection" ,gobject-introspection)
       ("gperf" ,gperf)
       ("perl" ,perl)
       ("pkg-config" ,pkg-config)
       ("python" ,python-2) ; incompatible with Python 3 (print syntax)
       ("ruby" ,ruby)))
    (propagated-inputs
     `(("gtk+" ,gtk+)
       ("libsoup" ,libsoup)))
    (inputs
     `(("at-spi2-core" ,at-spi2-core)
       ("enchant" ,enchant)
       ("geoclue" ,geoclue)
       ("gnutls" ,gnutls)
       ("gst-plugins-base" ,gst-plugins-base)
       ("gtk+-2" ,gtk+-2)
       ("harfbuzz" ,harfbuzz)
       ("icu4c" ,icu4c)
       ("libjpeg" ,libjpeg)
       ("libnotify" ,libnotify)
       ("libpng" ,libpng)
       ("libsecret" ,libsecret)
       ("libwebp" ,libwebp)
       ("libxcomposite" ,libxcomposite)
       ("libxml2" ,libxml2)
       ("libxslt" ,libxslt)
       ("libxt" ,libxt)
       ("mesa" ,mesa)
       ("sqlite" ,sqlite)))
    (home-page "http://www.webkitgtk.org/")
    (synopsis "Web content engine for GTK+")
    (description
     "WebKitGTK+ is a full-featured port of the WebKit rendering engine,
suitable for projects requiring any kind of web integration, from hybrid
HTML/CSS applications to full-fledged web browsers.")
    ;; WebKit's JavaScriptCore and WebCore components are available under
    ;; the GNU LGPL, while the rest is available under a BSD-style license.
    (license (list license:lgpl2.0
                   license:lgpl2.1+
                   license:bsd-2
                   license:bsd-3))))