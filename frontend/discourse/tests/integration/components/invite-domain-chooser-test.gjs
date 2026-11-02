import { hash } from "@ember/helper";
import { render } from "@ember/test-helpers";
import { module, test } from "qunit";
import InviteDomainChooser from "discourse/components/invite-domain-chooser";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import selectKit from "discourse/tests/helpers/select-kit-helper";

const DOMAINS = [
  { id: "ac.in", name: "ac.in" },
  { id: "aiitb.ac.in", name: "aiitb.ac.in" },
  { id: "citb.ac.in", name: "citb.ac.in" },
  { id: "iitb.ac.in", name: "iitb.ac.in" },
  { id: "nit.ac.in", name: "nit.ac.in" },
];

module("Integration | Component | invite-domain-chooser", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.set("subject", selectKit());
  });

  test("ranks an exact match first, then prefix matches, over other substring matches", async function (assert) {
    this.set("content", DOMAINS);

    await render(
      <template>
        <InviteDomainChooser
          @content={{this.content}}
          @options={{hash filterable=true}}
          @value={{null}}
        />
      </template>
    );

    await this.subject.expand();
    await this.subject.fillInFilter("iitb.ac.in");

    assert.deepEqual(
      this.subject.displayedContent().map((row) => row.name),
      ["iitb.ac.in", "aiitb.ac.in"],
      "the exact match ('iitb.ac.in') sorts before the substring match ('aiitb.ac.in'); 'citb.ac.in' and 'nit.ac.in' don't match at all"
    );
  });

  test("leaves content order untouched when the filter is empty", async function (assert) {
    this.set("content", DOMAINS);

    await render(
      <template>
        <InviteDomainChooser
          @content={{this.content}}
          @options={{hash filterable=true}}
          @value={{null}}
        />
      </template>
    );

    await this.subject.expand();

    assert.deepEqual(
      this.subject.displayedContent().map((row) => row.name),
      DOMAINS.map((d) => d.name),
      "every domain still shows, in its original order"
    );
  });
});
