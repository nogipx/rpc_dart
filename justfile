#!/usr/bin/env just --justfile
pubget_all:
  cd packages/rpc_dart && just get
  cd packages/rpc_dart_transports && just get

prepare_all:
  cd packages/rpc_dart && just prepare
  cd packages/rpc_dart_transports && just prepare