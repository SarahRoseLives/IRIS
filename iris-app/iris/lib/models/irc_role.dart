/// Defines the hierarchy of user roles in an IRC channel.
/// The order is important: roles are defined from lowest to highest privilege.
enum IrcRole {
  /// Regular user with no special permissions.
  user,

  /// A user with voice permissions (+).
  voiced,

  /// A half-operator (%).
  halfOp,

  /// A channel operator (@).
  op,

  /// A channel admin or protected operator (&).
  admin,

  /// The channel owner or founder (~).
  owner,
}