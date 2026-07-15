// A Batch Moderator badge says "this member can moderate their cohort", which
// is only worth saying when it is the member's highest role: an admin or site
// moderator already outranks it. The is_batch_moderator flag itself stays true
// for them, because grant/revoke and the admin user page still need it.
export function showsBatchModeratorBadge(user) {
  return !!user?.is_batch_moderator && !user.admin && !user.moderator;
}
