import { render } from "@ember/test-helpers";
import { module, test } from "qunit";
import SentInviteEmail from "discourse/components/modal/sent-invite-email";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";

module("Integration | Component | Modal | sent-invite-email", function (hooks) {
  setupRenderingTest(hooks);

  const noop = () => {};

  test("renders the body and headers as read-only prose instead of editable textareas", async function (assert) {
    const model = {
      subject: "You're invited",
      body: "Hi there,\n\nJoin us on the forum!",
      headers: "X-Mailer: test\nMessage-ID: <abc123@example.com>",
    };

    await render(
      <template>
        <SentInviteEmail
          @closeModal={{noop}}
          @inline={{true}}
          @model={{model}}
        />
      </template>
    );

    assert
      .dom(".sent-invite-email-modal textarea")
      .doesNotExist("neither field is an editable textarea");
    assert
      .dom(".sent-invite-email-body")
      .includesText("Hi there,")
      .includesText("Join us on the forum!");
    assert.strictEqual(
      document.querySelector(".sent-invite-email-body").tagName,
      "P",
      "the body renders as a <p>, not a <textarea>"
    );
    assert
      .dom(".sent-invite-email-headers")
      .includesText("X-Mailer: test")
      .includesText("Message-ID: <abc123@example.com>");
    assert.strictEqual(
      document.querySelector(".sent-invite-email-headers").tagName,
      "P",
      "the headers render as a <p>, not a <textarea>"
    );
  });
});
