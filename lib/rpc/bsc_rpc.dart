import "dart:convert";
import "package:http/http.dart" as http;

class BscRpc {
  final String url;
  BscRpc(this.url);
  int _id = 1;
  Future<Map<String, dynamic>> call(String method, List<dynamic> params) async {
    final payload = {
      "jsonrpc": "2.0",
      "id": _id++,
      "method": method,
      "params": params,
    };
    final res = await http
        .post(
          Uri.parse(url),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception("HTTP ${res.statusCode}: ${res.body}");
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json["error"] != null) {
      throw Exception("RPC error: ${json["error"]}");
    }
    return json;
  }
}
