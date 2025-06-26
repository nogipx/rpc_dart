#!/usr/bin/env just --justfile

test:
    fvm dart test --concurrency=1

gen:
    fvm dart pub global run packo runner -r

get:
    fvm dart pub global run packo pubget -r

prepare:
    fvm dart fix --apply
    fvm dart format -l 80 .
    reuse annotate -c "Karim \"nogipx\" Mamatkazin <nogipx@gmail.com>" -l "MIT" --skip-unrecognised -r lib
    rm -rf coverage
    fvm dart test test/ --coverage=coverage --reporter=compact --concurrency=5
    fvm dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --report-on=lib
    genhtml coverage/lcov.info -o coverage/html
    open coverage/html/index.html

dry:
    fvm dart pub publish --dry-run

publish:
    fvm dart pub publish

gen-logo:
    magick logo/logo.svg -resize 1000x1000 -background transparent logo/logo.webp 
