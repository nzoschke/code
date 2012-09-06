# Slug compiler

## Overview

A slug is a compressed archive of an app's code, to be stored in S3 and subsequently fetched by runtime instances (the [dyno grid](http://heroku.com/how/dyno_grid)) for execution of one of the app's processes.

The slug compiler is a program which transforms a Git repo into a slug.

## Setup

Fetching slug-compiler:

    $ git clone --recursive git://github.com/heroku/slug-compiler.git

For testing, you'll also want to have a sample app that you know works on Heroku sitting in a local directory on your system.

You'll need to install mksquashfs.

On Mac OS X you can do this: brew install squashfs

or (based on [these instructions](http://zettelchen.blogspot.com/2009/04/build-squashfs-tools-for-mac-os-x.html))

    $ curl -L http://sourceforge.net/projects/squashfs/files/squashfs/squashfs4.0/squashfs4.0.tar.gz/download > squashfs4.0.tar.gz
    $ tar xzvf squashfs4.0.tar.gz
    $ cd squashfs4.0/squashfs-tools
    $ sed -i.orig 's/\|FNM_EXTMATCH//' $(grep -l FNM_EXTMATCH *)
    $ sed -i.orig $'/#include "unsquashfs.h"/{i\\\n#include <sys/sysctl.h>\n}' unsquashfs.c
    $ make
    $ sudo cp mksquashfs unsquashfs /usr/bin

You'll also need to set ARCHFLAGS so slugc can compile the PG gem.

    $ export ARCHFLAGS="-arch x86_64"

On Debian-based systems it's just <tt>sudo apt-get install squashfs-tools</tt>.

## Usage

On Heroku, the slug compiler is invoked via a Git pre-recieve hook.  To test locally, you can run `slugc` manually against your sample app's Git repo, using either a stage 1 (`--output-dir`) or a stage 2 (`--output-slug`) build.

### Stage 1 build - output to directory

    $ bin/slugc --stack cedar --repo-dir $HOME/myapp/.git --output-dir /tmp/myapp-build --trace

    -----> Heroku receiving push
    -----> Rack app detected

    Compiled to directory /tmp/myapp-build/

Inspect the contents of `/tmp/myapp-build` to see the results of your slug compile.

### Stage 2 build - output to slug file

Building a slug file only works if you have a mksquashfs binary installed locally and in the path.

    $ bin/slugc --stack cedar --repo-dir $HOME/myapp/.git --output-slug /tmp/myapp-slug.img --trace

In this example, your slug will land in `/tmp/myapp-slug.img`.

### Stage 3 build - publish slug to S3, call Heroku to create a new release

Omitting either --output-slug or --output-dir will default to a full build, which publishes the slug by posting it to S3 then making a REST call to Heroku.  Typically you don't do this locally since it requires additional authentication data at compile-time.
