require 'messages/route_destinations_list_message'
require 'messages/route_create_message'
require 'messages/route_destination_update_message'
require 'messages/routes_list_message'
require 'messages/route_show_message'
require 'messages/route_update_message'
require 'messages/route_update_destinations_message'
require 'actions/update_route_destinations'
require 'decorators/include_route_domain_decorator'
require 'presenters/v3/route_presenter'
require 'presenters/v3/route_destinations_presenter'
require 'presenters/v3/paginated_list_presenter'
require 'actions/route_destination_update'
require 'actions/route_create'
require 'actions/route_delete'
require 'actions/route_update'
require 'actions/route_share'
require 'actions/route_unshare'
require 'fetchers/app_fetcher'
require 'fetchers/route_fetcher'
require 'fetchers/route_destinations_list_fetcher'

class RoutesController < ApplicationController
  def index
    message = RoutesListMessage.from_params(query_params)
    invalid_param!(message.errors.full_messages) unless message.valid?

    dataset = RouteFetcher.fetch(
      message,
      permission_queryer.readable_route_dataset,
      eager_loaded_associations: Presenters::V3::RoutePresenter.associated_resources
    )

    decorators = []
    decorators << IncludeRouteDomainDecorator if IncludeRouteDomainDecorator.match?(message.include)
    decorators << IncludeSpaceDecorator if IncludeSpaceDecorator.match?(message.include)
    decorators << IncludeOrganizationDecorator if IncludeOrganizationDecorator.match?(message.include)

    render status: :ok, json: Presenters::V3::PaginatedListPresenter.new(
      presenter: Presenters::V3::RoutePresenter,
      paginated_result: SequelPaginator.new.get_page(dataset, message.try(:pagination_options)),
      path: '/v3/routes',
      message: message,
      decorators: decorators,
    )
  end

  def show
    message = RouteShowMessage.from_params(query_params.merge(guid: hashed_params[:guid]))
    unprocessable!(message.errors.full_messages) unless message.valid?

    decorators = []
    decorators << IncludeRouteDomainDecorator if IncludeRouteDomainDecorator.match?(message.include)
    decorators << IncludeSpaceDecorator if IncludeSpaceDecorator.match?(message.include)
    decorators << IncludeOrganizationDecorator if IncludeOrganizationDecorator.match?(message.include)

    render status: :ok, json: Presenters::V3::RoutePresenter.new(
      route,
      decorators: decorators,
    )
  end

  def create
    FeatureFlag.raise_unless_enabled!(:route_creation) unless permission_queryer.can_write_globally?

    message = RouteCreateMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?

    space = Space.find(guid: message.space_guid)
    domain = Domain.find(guid: message.domain_guid)

    unprocessable_space! unless space
    unprocessable_domain! unless domain
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(space.guid)
    unprocessable_wildcard! if domain.shared? && message.wildcard? && !permission_queryer.can_write_globally?

    route = RouteCreate.new(user_audit_info).create(message: message, space: space, domain: domain)

    render status: :created, json: Presenters::V3::RoutePresenter.new(route)
  rescue RoutingApi::UaaUnavailable, UaaUnavailable
    service_unavailable!('Communicating with the Routing API failed because UAA is currently unavailable. Please try again later.')
  rescue RoutingApi::RoutingApiUnavailable
    service_unavailable!('The Routing API is currently unavailable. Please try again later.')
  rescue RoutingApi::RoutingApiDisabled
    service_unavailable!('The Routing API is disabled.')
  rescue RouteCreate::Error => e
    unprocessable!(e)
  end

  def update
    message = RouteUpdateMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?

    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    VCAP::CloudController::RouteUpdate.new.update(route: route, message: message)

    render status: :ok, json: Presenters::V3::RoutePresenter.new(route)
  end

  def destroy
    message = RouteShowMessage.from_params({ guid: hashed_params['guid'] })
    unprocessable!(message.errors.full_messages) unless message.valid?

    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    delete_action = RouteDeleteAction.new(user_audit_info)
    deletion_job = VCAP::CloudController::Jobs::DeleteActionJob.new(Route, route.guid, delete_action)
    pollable_job = Jobs::Enqueuer.new(deletion_job, queue: Jobs::Queues.generic).enqueue_pollable

    head :accepted, 'Location' => url_builder.build_url(path: "/v3/jobs/#{pollable_job.guid}")
  end

  def share_routes
    FeatureFlag.raise_unless_enabled!(:route_sharing)

    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    message = VCAP::CloudController::ToManyRelationshipMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?

    target_spaces = Space.where(guid: message.guids)
    check_spaces_exist_and_are_writeable!(route, message.guids, target_spaces)

    share = RouteShare.new
    share.create(route, target_spaces, user_audit_info)

    render status: :ok, json: Presenters::V3::ToManyRelationshipPresenter.new(
      "routes/#{route.guid}", route.shared_spaces, 'shared_spaces', build_related: false)
  rescue VCAP::CloudController::RouteShare::Error => e
    unprocessable!(e.message)
  end

  def unshare_route
    FeatureFlag.raise_unless_enabled!(:route_sharing)
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    space_guid = hashed_params[:space_guid]

    target_space = Space.first(guid: space_guid)
    resource_not_found!(:space) unless target_space && permission_queryer.can_read_from_space?(space_guid, target_space.organization.guid)

    if permission_queryer.can_manage_apps_in_space?(target_space.guid) == false
      unprocessable!("Unable to unshare route '#{route.uri}' from space '#{target_space.name}'. Ensure that the space and its containing org are not suspended.")
    end

    unshare = RouteUnshare.new
    unshare.unshare(route, target_space, user_audit_info)

    head :no_content
  rescue VCAP::CloudController::RouteUnshare::Error => e
    unprocessable!(e.message)
  end

  def relationships_shared_routes
    FeatureFlag.raise_unless_enabled!(:route_sharing)

    render status: :ok, json: Presenters::V3::ToManyRelationshipPresenter.new(
      "routes/#{route.guid}", route.shared_spaces, 'shared_spaces', build_related: false)
  end

  def index_destinations
    message = RouteShowMessage.from_params({ guid: hashed_params['guid'] })
    unprocessable!(message.errors.full_messages) unless message.valid?

    destinations_message = RouteDestinationsListMessage.from_params(query_params)
    unprocessable!(destinations_message.errors.full_messages) unless destinations_message.valid?
    route_mappings = RouteDestinationsListFetcher.new(message: destinations_message).fetch_for_route(route: route)

    render status: :ok, json: Presenters::V3::RouteDestinationsPresenter.new(route_mappings, route: route)
  end

  def insert_destinations
    message = RouteUpdateDestinationsMessage.new(hashed_params[:body])

    unprocessable!(message.errors.full_messages) unless message.valid?
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    UpdateRouteDestinations.add(message.destinations_array, route, apps_hash(message), user_audit_info)

    render status: :ok, json: Presenters::V3::RouteDestinationsPresenter.new(route.route_mappings, route: route)
  rescue UpdateRouteDestinations::Error => e
    unprocessable!(e.message)
  end

  def replace_destinations
    message = RouteUpdateDestinationsMessage.new(hashed_params[:body], replace: true)

    unprocessable!(message.errors.full_messages) unless message.valid?
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    UpdateRouteDestinations.replace(message.destinations_array, route, apps_hash(message), user_audit_info)

    render status: :ok, json: Presenters::V3::RouteDestinationsPresenter.new(route.route_mappings, route: route)
  rescue UpdateRouteDestinations::DuplicateDestinationError => e
    unprocessable!(e.message)
  end

  def update_destination
    message = RouteDestinationUpdateMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?

    route = Route.find(guid: hashed_params[:guid])
    route_not_found! unless route && permission_queryer.can_read_route?(route.space.guid, route.organization.guid)
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    destination = RouteMappingModel.find(guid: hashed_params[:destination_guid])
    unprocessable_destination! unless destination

    RouteDestinationUpdate.update(destination, message)

    render status: :ok, json: Presenters::V3::RouteDestinationPresenter.new(destination)
  rescue RouteDestinationUpdate::Error => e
    unprocessable!(e.message)
  end

  def route
    @route || begin
      @route = Route.find(guid: hashed_params[:guid])
      route_not_found! unless @route && permission_queryer.can_read_route?(@route.space.guid, @route.organization.guid)
      @route
    end
  end

  def apps_hash(update_message)
    @apps_hash || begin
      desired_app_guids = update_message.destinations.map { |dst| HashUtils.dig(dst, :app, :guid) }.compact

      @apps_hash = AppModel.where(guid: desired_app_guids).each_with_object({}) { |app, apps_hsh| apps_hsh[app.guid] = app; }
      validate_app_guids!(@apps_hash, desired_app_guids)
      validate_app_spaces!(@apps_hash, route)
      @apps_hash
    end
  end

  def destroy_destination
    route = Route.find(guid: hashed_params[:guid])
    route_not_found! unless route && permission_queryer.can_read_route?(route.space.guid, route.organization.guid)
    unauthorized! unless permission_queryer.can_manage_apps_in_space?(route.space.guid)

    destination = RouteMappingModel.find(guid: hashed_params[:destination_guid])
    unprocessable_destination! unless destination

    UpdateRouteDestinations.delete(destination, route, user_audit_info)

    head :no_content
  rescue UpdateRouteDestinations::Error => e
    unprocessable!(e.message)
  end

  def index_by_app
    message = RoutesListMessage.from_params(query_params.merge({ app_guids: hashed_params['guid'] }))
    invalid_param!(message.errors.full_messages) unless message.valid?

    app, space, org = AppFetcher.new.fetch(hashed_params['guid'])
    app_not_found! unless app && permission_queryer.can_read_from_space?(space.guid, org.guid)

    dataset = RouteFetcher.fetch(
      message,
      permission_queryer.readable_route_dataset,
      eager_loaded_associations: Presenters::V3::RoutePresenter.associated_resources
    )

    render status: :ok, json: Presenters::V3::PaginatedListPresenter.new(
      presenter: Presenters::V3::RoutePresenter,
      paginated_result: SequelPaginator.new.get_page(dataset, message.try(:pagination_options)),
      path: "/v3/apps/#{app.guid}/routes",
      message: message,
    )
  end

  private

  def route_not_found!
    resource_not_found!(:route)
  end

  def unprocessable_destination!
    unprocessable!('Unable to unmap route from destination. Ensure the route has a destination with this guid.')
  end

  def unprocessable_wildcard!
    unprocessable!('You do not have sufficient permissions to create a route with a wildcard host on a domain not scoped to an organization.')
  end

  def unprocessable_space!
    unprocessable!('Invalid space. Ensure that the space exists and you have access to it.')
  end

  def unprocessable_domain!
    unprocessable!('Invalid domain. Ensure that the domain exists and you have access to it.')
  end

  def unprocessable_protocol_host!
    unprocessable!('Hosts are not supported for TCP routes.')
  end

  def unprocessable_protocol_path!
    unprocessable!('Paths are not supported for TCP routes.')
  end

  def validate_app_guids!(apps_hash, desired_app_guids)
    existing_app_guids = apps_hash.keys

    missing_app_guids = desired_app_guids - (existing_app_guids & permission_queryer.readable_app_guids)

    unprocessable!("App(s) with guid(s) \"#{missing_app_guids.join('", "')}\" do not exist or you do not have access.") unless missing_app_guids.empty?
  end

  def validate_app_spaces!(apps_hash, route)
    if apps_hash.values.any? { |app| app.space != route.space }
      unprocessable!('Routes cannot be mapped to destinations in different spaces.')
    end
  end

  def app_not_found!
    resource_not_found!(:app)
  end

  def routing_api_client
    @routing_api_client ||= CloudController::DependencyLocator.instance.routing_api_client
  end

  def can_read_space?(space)
    permission_queryer.can_read_from_space?(space.guid, space.organization_guid)
  end

  def can_write_space?(space)
    permission_queryer.can_write_to_space?(space.guid)
  end

  def check_spaces_exist_and_are_writeable!(route, request_guids, found_spaces)
    unreadable_spaces = found_spaces.reject { |s| can_read_space?(s) }
    unwriteable_spaces = found_spaces.reject { |s| can_write_space?(s) || unreadable_spaces.include?(s) }

    not_found_space_guids = request_guids - found_spaces.map(&:guid)
    unreadable_space_guids = not_found_space_guids + unreadable_spaces.map(&:guid)
    unwriteable_space_guids = unwriteable_spaces.map(&:guid)

    if unreadable_space_guids.any? || unwriteable_space_guids.any?
      unreadable_error = unreadable_error_message(route.uri, unreadable_space_guids)
      unwriteable_error = unwriteable_error_message(route.uri, unwriteable_space_guids)

      error_msg = [unreadable_error, unwriteable_error].map(&:presence).compact.join("\n")

      unprocessable!(error_msg)
    end
  end

  def unreadable_error_message(uri, unreadable_space_guids)
    if unreadable_space_guids.any?
      unreadable_guid_list = unreadable_space_guids.map { |g| "'#{g}'" }.join(', ')

      "Unable to share route #{uri} with spaces [#{unreadable_guid_list}]. Ensure the spaces exist and that you have access to them."
    end
  end

  def unwriteable_error_message(uri, unwriteable_space_guids)
    if unwriteable_space_guids.any?
      unwriteable_guid_list = unwriteable_space_guids.map { |s| "'#{s}'" }.join(', ')

      "Unable to share route #{uri} with spaces [#{unwriteable_guid_list}]. "\
      'Write permission is required in order to share a route with a space.'
    end
  end
end
