import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import UppyUpload from "discourse/lib/uppy/uppy-upload";

export default class CreateInviteUploader extends Component {
  @tracked uploaded = false;
  @tracked pendingReview;

  uppyUpload = new UppyUpload(this, {
    id: "create-invite-uploader",
    type: "csv",
    autoStartUploads: false,
    uploadUrl: "/invites/upload_csv",
    preventDirectS3Uploads: true,
    validateUploadedFilesOptions: {
      bypassNewUserRestriction: true,
      csvOnly: true,
    },
    uploadDone: (response) => {
      this.uploaded = true;
      this.pendingReview = response?.pending_review;
    },
  });

  get submitDisabled() {
    return !this.uppyUpload?.filesAwaitingUpload || this.uppyUpload?.uploading;
  }

  @action
  startUpload() {
    this.uppyUpload.startUpload();
  }

  <template>
    <div ...attributes>
      {{yield
        (hash
          data=@data
          uploading=this.uppyUpload.uploading
          uploadProgress=this.uppyUpload.uploadProgress
          uploaded=this.uploaded
          pendingReview=this.pendingReview
          submitDisabled=this.submitDisabled
          startUpload=this.startUpload
        )
        this.uppyUpload.setup
      }}
    </div>
  </template>
}
