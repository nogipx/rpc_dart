#!/usr/bin/env just --justfile

prepare_all:
  cd packages/rpc_dart && just prepare
  cd packages/rpc_dart_transports && just prepare