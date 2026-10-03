import { click, fillIn, visit } from "@ember/test-helpers";
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
  let reinviteRequests;

  needs.hooks.beforeEach(() => {
    invitedRequests = [];
    reinviteAllRequests = [];
    reinviteRequests = [];
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
        available_domains: ["ac.in", "nit.ac.in"],
        available_statuses: STATUSES,
      });
    });

    server.post("/invites/reinvite-all", (request) => {
      reinviteAllRequests.push(helper.parsePostData(request.requestBody));
      return helper.response({ success: "OK" });
    });

    server.post("/invites/reinvite", (request) => {
      reinviteRequests.push(helper.parsePostData(request.requestBody));
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
      .dom(".resend-invite-modal")
      .includesText('with status "Skipped"', "confirm names the status");
    await click(".resend-invite-modal .resend-invite-confirm");

    assert.strictEqual(reinviteAllRequests.length, 1);
    assert.strictEqual(reinviteAllRequests[0].status, "skipped");
  });

  test("includes the active search term when resending all invites", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    // The search box only renders once a filter is active or the tab count
    // exceeds the always-visible threshold (see showSearch) -- select a
    // domain first so `.user-invite-search input` exists to fill in.
    const domainFilter = selectKit(".invite-domain-filter");
    await domainFilter.expand();
    await domainFilter.selectRowByValue("nit.ac.in");

    await fillIn(".user-invite-search input", "nit");
    await click(".user-invite-buttons .btn .d-icon-arrows-rotate");
    await click(".resend-invite-modal .resend-invite-confirm");

    assert.strictEqual(reinviteAllRequests.length, 1);
    assert.strictEqual(reinviteAllRequests[0].search, "nit");
  });

  test("passes keywords and ai_personalization along with a bulk resend", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    await click(".user-invite-buttons .btn .d-icon-arrows-rotate");
    await fillIn(".resend-invite-modal textarea", "robotics club");
    await click(".resend-invite-modal .resend-invite-confirm");

    assert.strictEqual(reinviteAllRequests.length, 1);
    assert.strictEqual(reinviteAllRequests[0].keywords, "robotics club");
    assert.strictEqual(reinviteAllRequests[0].ai_personalization, "true");
  });

  test("resends a single invite with its own keywords from the kebab menu", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    await click(
      "table.user-invite-list tbody tr:nth-child(1) .d-icon-ellipsis-vertical"
    );
    await click(".resend-invite");
    await fillIn(".resend-invite-modal textarea", "math olympiad");
    await click(".resend-invite-modal .resend-invite-confirm");

    assert.strictEqual(reinviteRequests.length, 1);
    assert.strictEqual(reinviteRequests[0].keywords, "math olympiad");
    assert.strictEqual(reinviteRequests[0].ai_personalization, "true");
  });

  test("offers the ac.in umbrella domain alongside specific institute domains", async function (assert) {
    await visit("/u/eviltrout/invited/pending");

    const domainFilter = selectKit(".invite-domain-filter");
    await domainFilter.expand();

    assert.true(
      domainFilter.rowByValue("ac.in").exists(),
      "ac.in is offered as a domain filter option"
    );

    await domainFilter.selectRowByValue("ac.in");
    assert.strictEqual(invitedRequests.at(-1).domain, "ac.in");
  });

  test("hides the status filter on the redeemed tab", async function (assert) {
    await visit("/u/eviltrout/invited/redeemed");

    assert.dom(".invite-status-filter").doesNotExist();
    assert.dom(".invite-domain-filter").exists();
  });
});

acceptance(
  "User invited - allow_any_email (unbound) invite row",
  function (needs) {
    needs.user();

    needs.pretender((server, helper) => {
      server.get("/u/eviltrout/invited.json", () => {
        return helper.response({
          // Mirrors Jobs::BulkInvite#send_invite's shape for an
          // allow_any_email row once sent: email is nil, the real
          // recipient lives in description, and the serializer now
          // includes emailed/delivery_status for it too (see
          // InviteSerializer#has_recipient?).
          invites: [
            {
              id: 99,
              invite_key: "key99",
              link: "http://localhost:3000/invites/key99",
              email: null,
              description: "asharani@ee.nits.ac.in",
              domain: null,
              emailed: true,
              delivery_status: "sent",
              can_delete_invite: true,
              custom_message: null,
              max_redemptions_allowed: 1,
              redemption_count: 0,
              created_at: "2026-09-23T04:47:13.195Z",
              updated_at: "2026-09-23T04:47:13.195Z",
              expires_at: "2026-12-22T04:47:00.000Z",
              expired: false,
              topics: [],
              groups: [],
            },
          ],
          can_see_invite_details: true,
          counts: { pending: 1, expired: 0, redeemed: 0, total: 1 },
          available_domains: [],
          available_statuses: STATUSES,
        });
      });
    });

    test("still shows the delivery pill and the preview/resend kebab items", async function (assert) {
      await visit("/u/eviltrout/invited/pending");

      assert.dom(".delivery-status-pill.--sent").exists();

      await click(
        "table.user-invite-list tbody tr:nth-child(1) .d-icon-ellipsis-vertical"
      );
      assert.dom(".preview-sent-email").exists();
      assert.dom(".resend-invite").exists();
    });
  }
);
