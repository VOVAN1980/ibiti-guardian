enum SubscriptionPlan {
  free,
  monthly,
  yearly;

  String toJson() => name;

  static SubscriptionPlan fromJson(String json) {
    return SubscriptionPlan.values.firstWhere(
      (e) => e.name == json,
      orElse: () => SubscriptionPlan.free,
    );
  }
}
