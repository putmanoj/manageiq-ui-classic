class FloatingIpController < ApplicationController
  before_action :check_privileges
  before_action :get_session_data
  after_action :cleanup_action
  after_action :set_session_data

  include Mixins::GenericButtonMixin
  include Mixins::GenericListMixin
  include Mixins::GenericSessionMixin
  include Mixins::GenericShowMixin
  include Mixins::GenericFormMixin
  include Mixins::BreadcrumbsMixin

  def self.display_methods
    %w[]
  end

  menu_section :net
  feature_for_actions "#{controller_name}_show_list", *ADV_SEARCH_ACTIONS

  def button
    @edit = session[:edit] # Restore @edit for adv search box
    params[:display] = @display if %w[vms instances images].include?(@display)
    params[:page] = @current_page unless @current_page.nil? # Save current page for list refresh

    @refresh_div = "main_div"

    case params[:pressed]
    when 'floating_ip_delete'
      delete_floating_ips
    when "floating_ip_edit"
      javascript_redirect(:action => "edit", :id => checked_item_id(params))
    when "floating_ip_new"
      javascript_redirect(:action => "new")
    else
      super
    end
  end

  def create
    assert_privileges("floating_ip_new")
    case params[:button]
    when "add"
      options = form_params
      ems = ExtManagementSystem.find(options[:ems_id])

      if FloatingIp.class_by_ems(ems)&.supports?(:create)
        options.delete(:ems_id)
        task_id = ems.create_floating_ip_queue(session[:userid], options)

        unless task_id.kind_of?(Integer)
          add_flash(_("Floating IP creation failed: Task start failed"), :error)
        end

        if @flash_array
          javascript_flash(:spinner_off => true)
        else
          initiate_wait_for_task(:task_id => task_id, :action => "create_finished")
        end
      else
        @in_a_form = true
        add_flash(_(FloatingIp.unsupported_reason(:create)), :error)
        drop_breadcrumb(:name => _("Add New Floating IP "), :url => "/floating_ip/new")
        javascript_flash
      end
    end
  end

  def create_finished
    task_id = params[:task_id]
    floating_ip_address = params[:address]
    task = MiqTask.find(task_id)
    if MiqTask.status_ok?(task.status)
      add_flash(_("Floating IP \"%{address}\" created") % { :address => floating_ip_address })
    else
      add_flash(_("Unable to create Floating IP \"%{address}\": %{details}") % {:address => floating_ip_address,
                                                                                :details => task.message}, :error)
    end

    @breadcrumbs&.pop
    session[:edit] = nil
    flash_to_session
    javascript_redirect(:action => "show_list")
  end

  def delete_floating_ips
    assert_privileges("floating_ip_delete")
    floating_ips = find_records_with_rbac(FloatingIp, checked_or_params)
    process_floating_ips(floating_ips, "destroy")

    # refresh the list if applicable
    if @lastaction == "show_list"
      show_list
      @refresh_partial = "layouts/gtl"
    elsif @lastaction == "show" && @layout == "floating_ip"
      @single_delete = true unless flash_errors?
      if @flash_array.nil?
        add_flash(_("The selected Floating IP was deleted"))
      else # or (if we deleted what we were showing) we redirect to the listing
        flash_to_session
        javascript_redirect(:action => 'show_list')
      end
    end
  end

  def edit
    assert_privileges("floating_ip_edit")
    @floating_ip = find_record_with_rbac(FloatingIp, params[:id])
    @in_a_form = true
    drop_breadcrumb(:name => _("Associate Floating IP \"%{address}\"") % { :address => @floating_ip.address },
                    :url  => "/floating_ip/edit/#{@floating_ip.id}")
  end

  def new
    assert_privileges("floating_ip_new")
    @floating_ip = FloatingIp.new
    @in_a_form = true
    drop_breadcrumb(:name => _("Add New Floating IP"), :url => "/floating_ip/new")
  end

  def download_data
    assert_privileges('floating_ip_show_list')
    super
  end

  def download_summary_pdf
    assert_privileges('floating_ip_show')
    super
  end

  private

  def textual_group_list
    [%i[properties relationships], %i[tags]]
  end
  helper_method :textual_group_list

  def form_params
    options = {}
    copy_params_if_present(options, params, %i[address cloud_network_id cloud_tenant_id])
    options[:ems_id] = params[:ems_id] if params[:ems_id] && params[:ems_id] != 'new'
    if params[:network_port] && params[:network_port][:ems_ref]
      options[:network_port_ems_ref] = params[:network_port][:ems_ref]
    end
    options
  end

  # dispatches operations to multiple floating_ips
  def process_floating_ips(floating_ips, operation)
    return if floating_ips.empty?

    if operation == "destroy"
      floating_ips.each do |floating_ip|
        audit = {
          :event        => "floating_ip_record_delete_initiated",
          :message      => "[#{floating_ip.address}] Record delete initiated",
          :target_id    => floating_ip.id,
          :target_class => "FloatingIp",
          :userid       => session[:userid]
        }
        AuditEvent.success(audit)
        floating_ip.delete_floating_ip_queue(session[:userid])
      end
      add_flash(n_("Delete initiated for %{number} Floating IP.",
                   "Delete initiated for %{number} Floating IPs.",
                   floating_ips.length) % {:number => floating_ips.length})
    end
  end

  def breadcrumbs_options
    record_info = @record || @floating_id
    record_name = :address
    {
      :breadcrumbs  => [
        breadcrumbs_menu_section,
        {:title => _("Floating IPs"), :url => controller_url},
      ],
      :record_info  => record_info,
      :record_title => record_name,
    }
  end
end
