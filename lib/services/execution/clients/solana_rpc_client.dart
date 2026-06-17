import 'dart:convert';
import 'package:http/http.dart' as http;

class SolanaRpcException implements Exception {
  final String message;
  const SolanaRpcException(this.message);

  @override
  String toString() => 'SolanaRpcException: $message';
}

abstract class SolanaRpcClient {
  Future<BigInt> getBalanceLamports(String address);
  Future<String> getLatestBlockhash();
  Future<String> sendRawTransaction(String base64Transaction);
  Future<Map<String, dynamic>> simulateTransaction(String base64Transaction);

  /// Fetches all SPL token accounts owned by [ownerAddress].
  /// Returns a list of parsed token account data.
  Future<List<SplTokenAccount>> getTokenAccountsByOwner(String ownerAddress);
}

class SolanaHttpRpcClient implements SolanaRpcClient {
  final String rpcUrl;
  final http.Client _http;

  SolanaHttpRpcClient({
    this.rpcUrl = 'https://api.mainnet-beta.solana.com',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Future<Map<String, dynamic>> _post(
      String method, List<dynamic> params) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    });

    final res = await _http
        .post(
          Uri.parse(rpcUrl),
          headers: const {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 15));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SolanaRpcException(
        'HTTP ${res.statusCode}: ${res.body}',
      );
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;

    if (decoded['error'] != null) {
      throw SolanaRpcException(
        'RPC error: ${jsonEncode(decoded["error"])}',
      );
    }

    return decoded;
  }

  @override
  Future<BigInt> getBalanceLamports(String address) async {
    final json = await _post('getBalance', [
      address,
      {'commitment': 'confirmed'}
    ]);

    final value = json['result']?['value'];
    if (value is! num) {
      throw const SolanaRpcException('Invalid getBalance response');
    }

    return BigInt.from(value);
  }

  @override
  Future<String> getLatestBlockhash() async {
    final json = await _post('getLatestBlockhash', [
      {'commitment': 'confirmed'}
    ]);

    final blockhash = json['result']?['value']?['blockhash'];
    if (blockhash is! String || blockhash.isEmpty) {
      throw const SolanaRpcException('Invalid getLatestBlockhash response');
    }

    return blockhash;
  }

  @override
  Future<String> sendRawTransaction(String base64Transaction) async {
    final json = await _post('sendTransaction', [
      base64Transaction,
      {
        'encoding': 'base64',
        'skipPreflight': false,
        'preflightCommitment': 'confirmed',
        'maxRetries': 3,
      }
    ]);

    final signature = json['result'];
    if (signature is! String || signature.isEmpty) {
      throw const SolanaRpcException('Invalid sendTransaction response');
    }

    return signature;
  }

  @override
  Future<Map<String, dynamic>> simulateTransaction(
      String base64Transaction) async {
    final json = await _post('simulateTransaction', [
      base64Transaction,
      {
        'encoding': 'base64',
        'replaceRecentBlockhash': true,
        'sigVerify': false,
        'commitment': 'confirmed',
      }
    ]);

    final result = json['result'];
    if (result is! Map<String, dynamic>) {
      throw const SolanaRpcException('Invalid simulateTransaction response');
    }

    return result;
  }

  @override
  Future<List<SplTokenAccount>> getTokenAccountsByOwner(
      String ownerAddress) async {
    final json = await _post('getTokenAccountsByOwner', [
      ownerAddress,
      {'programId': 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'},
      {
        'encoding': 'jsonParsed',
        'commitment': 'confirmed',
      }
    ]);

    final accounts = json['result']?['value'] as List<dynamic>? ?? [];
    final result = <SplTokenAccount>[];

    for (final account in accounts) {
      try {
        final parsed = account['account']?['data']?['parsed']?['info'];
        if (parsed == null) continue;

        final mint = parsed['mint'] as String? ?? '';
        final tokenAmount = parsed['tokenAmount'];
        if (tokenAmount == null || mint.isEmpty) continue;

        final uiAmount = (tokenAmount['uiAmount'] as num?)?.toDouble() ?? 0.0;
        final decimals = (tokenAmount['decimals'] as num?)?.toInt() ?? 0;
        final rawAmount = tokenAmount['amount'] as String? ?? '0';

        if (uiAmount <= 0) continue; // Skip zero balances

        result.add(SplTokenAccount(
          mint: mint,
          balance: uiAmount,
          rawAmount: BigInt.tryParse(rawAmount) ?? BigInt.zero,
          decimals: decimals,
          accountAddress: account['pubkey'] as String? ?? '',
        ));
      } catch (_) {
        // Skip malformed accounts
      }
    }

    return result;
  }
}

/// Represents a single SPL token account with its balance.
class SplTokenAccount {
  final String mint;
  final double balance;
  final BigInt rawAmount;
  final int decimals;
  final String accountAddress;

  const SplTokenAccount({
    required this.mint,
    required this.balance,
    required this.rawAmount,
    required this.decimals,
    required this.accountAddress,
  });

  @override
  String toString() =>
      'SplTokenAccount(mint: $mint, balance: $balance, decimals: $decimals)';
}
