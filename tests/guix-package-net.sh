# GNU Guix --- Functional package management for GNU
# Copyright © 2012, 2013, 2014, 2015 Ludovic Courtès <ludo@gnu.org>
# Copyright © 2013 Nikita Karetnikov <nikita@karetnikov.org>
#
# This file is part of GNU Guix.
#
# GNU Guix is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or (at
# your option) any later version.
#
# GNU Guix is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

#
# Test the `guix package' command-line utility.  This test requires network
# access and is skipped when that is lacking.
#

guix package --version

readlink_base ()
{
    basename `readlink "$1"`
}

# Return true if a typical shebang in the store would exceed Linux's default
# static limit.
shebang_too_long ()
{
    test `echo $NIX_STORE_DIR/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-binaries-0/bin/bash | wc -c` \
	 -ge 128
}

if ! guile -c '(getaddrinfo "www.gnu.org" "80" AI_NUMERICSERV)' 2> /dev/null \
	|| shebang_too_long
then
    # Skipping.
    exit 77
fi


profile="t-profile-$$"
rm -f "$profile"

trap 'rm -f "$profile" "$profile-"[0-9]* ; rm -rf t-home-'"$$" EXIT


guix package --bootstrap -p "$profile" -i guile-bootstrap
test -L "$profile" && test -L "$profile-1-link"
! test -f "$profile-2-link"
test -f "$profile/bin/guile"

boot_make="(@@ (gnu packages commencement) gnu-make-boot0)"
boot_make_drv="`guix build -e "$boot_make" | grep -v -e -debug`"
guix package --bootstrap -p "$profile" -i "$boot_make_drv"
test -L "$profile-2-link"
test -f "$profile/bin/make" && test -f "$profile/bin/guile"

# Check whether `--list-installed' works.
# XXX: Change the tests when `--install' properly extracts the package
# name and version string.
installed="`guix package -p "$profile" --list-installed | cut -f1 | xargs echo | sort`"
case "x$installed" in
    "guile-bootstrap make-boot0")
        true;;
    "make-boot0 guile-bootstrap")
        true;;
    "*")
        false;;
esac

test "`guix package -p "$profile" -I 'g.*e' | cut -f1`" = "guile-bootstrap"

# List generations.
test "`guix package -p "$profile" -l | cut -f1 | grep guile | head -n1`" \
     = "  guile-bootstrap"

# Exit with 1 when a generation does not exist.
if guix package -p "$profile" --list-generations=42;
then false; else true; fi
if guix package -p "$profile" --switch-generation=99;
then false; else true; fi

# Remove a package.
guix package --bootstrap -p "$profile" -r "guile-bootstrap"
test -L "$profile-3-link"
test -f "$profile/bin/make" && ! test -f "$profile/bin/guile"

# Roll back.
guix package --roll-back -p "$profile"
test "`readlink_base "$profile"`" = "$profile-2-link"
test -x "$profile/bin/guile" && test -x "$profile/bin/make"
guix package --roll-back -p "$profile"
test "`readlink_base "$profile"`" = "$profile-1-link"
test -x "$profile/bin/guile" && ! test -x "$profile/bin/make"

# Switch to the rolled generation and switch back.
guix package -p "$profile" --switch-generation=2
test "`readlink_base "$profile"`" = "$profile-2-link"
guix package -p "$profile" --switch-generation=-1
test "`readlink_base "$profile"`" = "$profile-1-link"

# Move to the empty profile.
for i in `seq 1 3`
do
    guix package --bootstrap --roll-back -p "$profile"
    ! test -f "$profile/bin"
    ! test -f "$profile/lib"
    test "`readlink_base "$profile"`" = "$profile-0-link"
done

# Test that '--list-generations' does not output the zeroth generation.
test -z "`guix package -p "$profile" -l 0`"

# Reinstall after roll-back to the empty profile.
guix package --bootstrap -p "$profile" -e "$boot_make"
test "`readlink_base "$profile"`" = "$profile-1-link"
test -x "$profile/bin/guile" && ! test -x "$profile/bin/make"

# Check that the first generation is the current one.
test "`guix package -p "$profile" -l 1 | cut -f3 | head -n1`" = "(current)"

# Roll-back to generation 0, and install---all at once.
guix package --bootstrap -p "$profile" --roll-back -i guile-bootstrap
test "`readlink_base "$profile"`" = "$profile-1-link"
test -x "$profile/bin/guile" && ! test -x "$profile/bin/make"

# Install Make.
guix package --bootstrap -p "$profile" -e "$boot_make"
test "`readlink_base "$profile"`" = "$profile-2-link"
test -x "$profile/bin/guile" && test -x "$profile/bin/make"
grep "`guix build -e "$boot_make"`" "$profile/manifest"

# Make a "hole" in the list of generations, and make sure we can
# roll back and switch "over" it.
rm "$profile-1-link"
guix package --bootstrap -p "$profile" --roll-back
test "`readlink_base "$profile"`" = "$profile-0-link"
guix package -p "$profile" --switch-generation=+1
test "`readlink_base "$profile"`" = "$profile-2-link"

# Make sure LIBRARY_PATH gets listed by `--search-paths'.
guix package --bootstrap -p "$profile" -i guile-bootstrap -i gcc-bootstrap
guix package --search-paths -p "$profile" | grep LIBRARY_PATH

# Roll back so we can delete #3 below.
guix package -p "$profile" --switch-generation=2

# Delete the third generation and check that it was actually deleted.
guix package -p "$profile" --delete-generations=3
test -z "`guix package -p "$profile" -l 3`"


#
# Try with the default profile.
#

XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_CACHE_HOME
HOME="$PWD/t-home-$$"
export HOME

mkdir -p "$HOME"

# Get the canonical directory name so that 'guix package' recognizes it.
HOME="`cd $HOME; pwd -P`"

guix package --bootstrap -e "$boot_make"
test -f "$HOME/.guix-profile/bin/make"

guix package --bootstrap --roll-back
! test -f "$HOME/.guix-profile/bin/make"