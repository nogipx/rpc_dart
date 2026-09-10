// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 311 removed an unreachable `?? 4 * 1024 * 1024` from two copies of the
// un-consumed-window resolver and reported it with "dead code has no runtime
// witness by definition".
//
// True of the deleted clause. FALSE of the function's contract, which is what
// actually needed pinning — round 313 is that correction.
//
// The contract has one surprising clause, and it is the one an operator will
// meet: RpcSecurityPolicy.flowControlWindowBytes documents null as "disable",
// and its own doc advises transports with native flow control — HTTP/2 — to do
// exactly that. Setting it does NOT disable the bound here, because the two
// mechanisms are different: switching off rpc-level GRANTS is right for HTTP/2,
// leaving the un-consumed bound off is not, since the bytes still arrive and
// still have to go somewhere.
//
// Nothing said so before 311, and nothing checked it before this.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';
import 'package:test/test.dart';

void main() {
  test('an explicit window is used as given', () {
    expect(
      unconsumedWindowFor(
        const RpcSecurityPolicy(flowControlWindowBytes: 123456),
      ),
      123456,
    );
  });

  test('the default policy resolves to the policy default', () {
    // NOT a literal repeated here: the assertion reads the policy, so changing
    // the default moves both sides together. Two copies of the transport used
    // to restate 4 MiB themselves, which is what 311 removed.
    expect(
      unconsumedWindowFor(const RpcSecurityPolicy()),
      const RpcSecurityPolicy().flowControlWindowBytes,
    );
  });

  test('null does NOT disable the un-consumed bound', () {
    // The clause worth a test. An operator who follows the policy's own advice
    // for HTTP/2 sets null and still gets a bound — by design.
    expect(
      unconsumedWindowFor(
        const RpcSecurityPolicy(flowControlWindowBytes: null),
      ),
      const RpcSecurityPolicy().flowControlWindowBytes,
      reason:
          'null must fall back to the policy default, not to zero and not to '
          'unbounded: the bytes still arrive and still have to go somewhere',
    );
  });

  test('the fallback the resolver leans on is really non-null', () {
    // This is what made the third `??` clause unreachable, and it is the only
    // thing standing between the resolver and a null-assertion throw. If the
    // policy default ever becomes null, THIS fails first and names the reason,
    // instead of the transport quietly substituting a number it invented.
    expect(
      const RpcSecurityPolicy().flowControlWindowBytes,
      isNotNull,
      reason:
          'unconsumedWindowFor asserts this is non-null; a null default must '
          'be a deliberate decision with a new fallback, not a silent 4 MiB',
    );
  });
}
