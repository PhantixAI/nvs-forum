import { render } from "@ember/test-helpers";
import { module, test } from "qunit";
import UserNav from "discourse/components/user-nav";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";

module("Integration | Component | UserNav", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.user = {
      adminPath: "/admin/users/1/eviltrout",
      profile_hidden: false,
    };
  });

  test("shows the admin Manage link as the first item for a staff viewer on mobile", async function (assert) {
    await render(
      <template>
        <UserNav @isMobileView={{true}} @isStaff={{true}} @user={{this.user}} />
      </template>
    );

    assert.dom(".user-nav__admin").exists("the Manage link renders");
    assert
      .dom(".user-nav > li:first-child")
      .hasClass(
        "user-nav__admin",
        "Manage is the first item, visible without scrolling the strip"
      );
    assert
      .dom(".user-nav > li:nth-child(2)")
      .hasClass("user-nav__summary", "Summary follows directly after it");
  });

  test("does not show the admin Manage link for a non-staff viewer on mobile", async function (assert) {
    await render(
      <template>
        <UserNav
          @isMobileView={{true}}
          @isStaff={{false}}
          @user={{this.user}}
        />
      </template>
    );

    assert.dom(".user-nav__admin").doesNotExist();
  });

  test("does not show the admin Manage link for a staff viewer on desktop", async function (assert) {
    await render(
      <template>
        <UserNav
          @isMobileView={{false}}
          @isStaff={{true}}
          @user={{this.user}}
        />
      </template>
    );

    assert
      .dom(".user-nav__admin")
      .doesNotExist(
        "desktop keeps its own standalone Admin button elsewhere -- UserNav itself never renders this link outside mobile"
      );
  });
});
