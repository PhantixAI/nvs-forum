import { module, test } from "qunit";
import { showsBatchModeratorBadge } from "discourse/lib/batch-moderator-badge";

module("Unit | Lib | batch-moderator-badge", function () {
  test("shows for a Batch Moderator with no higher role", function (assert) {
    assert.true(showsBatchModeratorBadge({ is_batch_moderator: true }));
  });

  test("defers to admin and site moderator", function (assert) {
    assert.false(
      showsBatchModeratorBadge({ is_batch_moderator: true, admin: true })
    );
    assert.false(
      showsBatchModeratorBadge({ is_batch_moderator: true, moderator: true })
    );
    assert.false(
      showsBatchModeratorBadge({
        is_batch_moderator: true,
        admin: true,
        moderator: true,
      })
    );
  });

  test("does not show for anyone who is not a Batch Moderator", function (assert) {
    assert.false(showsBatchModeratorBadge({ is_batch_moderator: false }));
    assert.false(showsBatchModeratorBadge({}));
    assert.false(showsBatchModeratorBadge(null));
    assert.false(showsBatchModeratorBadge(undefined));
  });
});
