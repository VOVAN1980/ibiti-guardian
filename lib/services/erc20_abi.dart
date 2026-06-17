class Erc20Abi {
  // keccak256("approve(address,uint256)") first 4 bytes = 0x095ea7b3
  static const String approveSelector = "095ea7b3";
  static String _strip0x(String s) => s.startsWith("0x") ? s.substring(2) : s;
  static String _pad64(String hex) => hex.padLeft(64, "0");
  static String encodeApprove({
    required String spender,
    required BigInt value,
  }) {
    final spenderHex = _strip0x(spender).toLowerCase();
    final valueHex = value.toRadixString(16);
    final data = approveSelector + _pad64(spenderHex) + _pad64(valueHex);
    return "0x$data";
  }
}
