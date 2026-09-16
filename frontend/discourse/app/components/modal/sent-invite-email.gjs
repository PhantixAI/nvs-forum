import { Textarea } from "@ember/component";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

const SentInviteEmail = <template>
  <DModal
    class="sent-invite-email-modal"
    @bodyClass="sent-invite-email"
    @closeModal={{@closeModal}}
    @title={{i18n "user.invited.sent_email.modal.title"}}
  >
    <:body>
      <div class="control-group">
        <label>{{i18n "user.invited.sent_email.modal.subject"}}</label>
        <div class="controls">
          {{@model.subject}}
        </div>
      </div>

      <div class="control-group">
        <label>{{i18n "user.invited.sent_email.modal.body"}}</label>
        <div class="controls">
          <Textarea @value={{@model.body}} />
        </div>
      </div>

      <div class="control-group">
        <label>{{i18n "user.invited.sent_email.modal.headers"}}</label>
        <div class="controls">
          <Textarea wrap="off" @value={{@model.headers}} />
        </div>
      </div>
    </:body>
  </DModal>
</template>;

export default SentInviteEmail;
