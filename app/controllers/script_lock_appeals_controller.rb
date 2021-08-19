class ScriptLockAppealsController < ApplicationController
  layout 'scripts', except: :index

  before_action :load_script, except: :index
  before_action :authenticate_user!, except: [:index, :show]
  before_action :load_script_lock_appeal, only: [:show, :dismiss, :unlock]
  before_action :authorize_by_script_id, only: [:new, :create]
  before_action :ensure_locked, only: [:new, :create]
  before_action :authorize_for_moderators_only, only: [:dismiss, :unlock]

  def new
    @script_lock_appeal = @script.script_lock_appeals.build
  end

  def create
    @script_lock_appeal = @script.script_lock_appeals.create!(script_lock_appeal_params)
    redirect_to script_path(@script), flash: { notice: 'Your appeal has been received and a moderator will review it.' }
  end

  def show; end

  def dismiss
    @script_lock_appeal.update!(resolution: 'dismissed')

    ScriptLockAppealMailer.dismiss(@script_lock_appeal, site_name).deliver_later

    redirect_to script_path(@script), flash: { notice: 'Appeal has been dismissed.' }
  end

  def unlock
    @script_lock_appeal.update!(resolution: 'unlocked')

    ma = ModeratorAction.new
    ma.moderator = current_user
    ma.script = @script
    ma.script_lock_appeal = @script_lock_appeal
    ma.action = 'Undelete'
    ma.save!

    @script.delete_type = nil
    @script.replaced_by_script_id = nil
    @script.delete_reason = nil
    @script.permanent_deletion_request_date = nil
    @script.save!

    @script.script_lock_appeals.unresolved.update_all(resolution: 'unlocked')

    ScriptLockAppealMailer.unlock(@script_lock_appeal, site_name).deliver_later

    redirect_to script_path(@script), flash: { notice: 'Script has been unlocked.' }
  end

  def index
    @script_lock_appeals = ScriptLockAppeal.unresolved
  end

  protected

  def load_script
    @script = Script.find(params[:script_id])
  end

  def load_script_lock_appeal
    @script_lock_appeal = @script.script_lock_appeals.find(params[:id])
  end

  def ensure_locked
    render_404('Script is not locked.') unless @script.locked?
  end

  def script_lock_appeal_params
    params.require(:script_lock_appeal).permit(:text, :text_markup, :report_id)
  end
end