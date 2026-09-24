import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import selectKit from "discourse/tests/helpers/select-kit-helper";

const STATUSES = [
  "scheduled",
  "pending",
  "skipped",
  "sent",
  "delivered",
  "bounced",
  "complained",
];

function invite(id, email, delivery_status) {
  return {
    id,
    invite_key: `key${id}`,
    link: `http://localhost:3000/invites/key${id}`,
    email,
    domain: null,
    emailed: true,
    delivery_status,
    can_delete_invite: true,
    custom_message: null,
    created_at: "2026-09-23T04:47:13.195Z",
    updated_at: "2026-09-23T04:47:13.195Z",
    expires_at: "2026-12-22T04:47:00.000Z",
    expired: false,
    topics: [],
    groups: [],
  };
}

acceptance("User invited - delivery status filter", function (needs) {
  needs.user();

  let invitedRequests;
  let reinviteAllRequests;

  needs.hooks.beforeEach(() => {
    invitedRequests = [];
    reinviteAllRequests = [];
  });

  needs.pretender((server, helper) => {
    server.get("/u/eviltrout/invited.json", (request) => {
      invitedRequests.push(request.queryParams);
      const status = request.queryParams.status;
      const all =
        request.queryParams.filter === "redeemed"
          ? []
          : [
              invite(1, "skipped@nit.ac.in", "skipped"),
              invite(2, "sent@nit.ac.in", "sent"),
            ];

      return helper.response({
        invites: status ? all.filter((i) => i.delivery_status === status) : all,
        can_see_invite_details: true,
        counts: { pending: 2, expired: 0, redeemed: 0, total: 2 },
        available_domains: ["nit.ac.in"],
        available_statuses: STATUSES,
      });
    });

    server.post("/invites/reinvite-all", (request) => {
      reinviteAllRequests.push(helper.parsePostData(request.requestBody));
      return helper.response({ success: "OK" });
    });
  });

  test("renders a pill for sent and skipped invites", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    assert.dom(".delivery-status-pill.--skipped").hasText("Skipped");
    assert.dom(".delivery-status-pill.--sent").hasText("Sent");
  });

  test("filters by status and resends only that status", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    const statusFilter = selectKit(".invite-status-filter");
    await statusFilter.expand();
    await statusFilter.selectRowByValue("skipped");

    assert.strictEqual(invitedRequests.at(-1).status, "skipped");
    assert.dom(".delivery-status-pill.--skipped").exists();
    assert.dom(".delivery-status-pill.--sent").doesNotExist();

    await click(".user-invite-buttons .btn .d-icon-arrows-rotate");
    assert
      .dom(".dialog-body")
      .includesText('with status "Skipped"', "confirm names the status");
    await click(".dialog-footer .btn-primary");

    assert.strictEqual(reinviteAllRequests.length, 1);
    assert.strictEqual(reinviteAllRequests[0].status, "skipped");
  });

  test("hides the status filter on the redeemed tab", async function (assert) {
    await visit("/u/eviltrout/invited/redeemed");

    assert.dom(".invite-status-filter").doesNotExist();
    assert.dom(".invite-domain-filter").exists();
  });
});
