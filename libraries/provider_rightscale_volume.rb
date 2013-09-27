#
# Cookbook Name:: rightscale_volume
#
# Copyright RightScale, Inc. All rights reserved.
# All access and use subject to the RightScale Terms of Service available at
# http://www.rightscale.com/terms.php and, if applicable, other agreements
# such as a RightScale Master Subscription Agreement.

require "chef/provider"

class Chef
  class Provider
    # A provider class for rightscale_volume cookbook.
    class RightscaleVolume < Chef::Provider
      # Loads @current_resource instance variable with device hash values in the
      # node if device exists in the node. Also initializes platform methods
      # and right_api_client for making API calls.
      #
      def load_current_resource
        @current_resource ||= Chef::Resource::RightscaleVolume.new(@new_resource.name)
        @current_resource.name = @new_resource.name

        @api_client = initialize_api_client

        # Set @current_resource with device hash values in the node
        # If device hash is not present in the node, it may not have been
        # created or been deleted
        device_hash = node['rightscale_volume'][@current_resource.name]
        unless device_hash.nil?
          @current_resource.size = device_hash['size']
          @current_resource.device = device_hash['device']
          @current_resource.description = device_hash['description']
          @current_resource.volume_id = device_hash['volume_id']
          @current_resource.state = device_hash['state']
          @current_resource.max_snapshots = device_hash['max_snapshots']
          @current_resource.timeout = device_hash['timeout']
        end
        @current_resource.timeout = @new_resource.timeout

        @current_resource
      end

      # Creates a new volume with the given name. If snapshot_id is provided,
      # a new volume is created from the snapshot.
      #
      def action_create
        # If volume already created do nothing.
        # We can check if volume already exist by checking its state.
        if @current_resource.state
          msg = "Volume '#{@current_resource.name}' already exists."
          msg << " Volume ID: '#{@current_resource.volume_id}'" if @current_resource.volume_id
          msg << " Attached to: '#{@current_resource.device}'" if @current_resource.device
          Chef::Log.info msg
          return
        end

        raise "Cannot create a volume with specific ID." if @new_resource.volume_id

        # If snapshot_id is provided restore volume from the specified snapshot.
        if @new_resource.snapshot_id
          Chef::Log.info "Creating a new volume from snapshot '#{@new_resource.snapshot_id}'..."
        else
          Chef::Log.info "Creating a new volume '#{@current_resource.name}'..."
        end
        volume = create_volume(
            @new_resource.name,
            @new_resource.size,
            @new_resource.description,
            @new_resource.snapshot_id,
            @new_resource.options
          )
        @current_resource.volume_id = volume.resource_uid
        @current_resource.size = volume.size
        @current_resource.description = volume.description
        @current_resource.state = volume.status

        # Store all volume information in node variable
        save_device_hash
        @new_resource.updated_by_last_action(true)
        Chef::Log.info "Volume '#{@current_resource.name}' successfully created"
      end

      # Deletes a volume with the given name.
      #
      def action_delete
        # If volume already deleted, do nothing.
        if @current_resource.state.nil?
          Chef::Log.info "Device '#{@current_resource.name}' does not exist." +
            " This device may have been deleted or never been created."
          return
        elsif @current_resource.state == "in-use"
          Chef::Log.info "Volume is not available for deletion. Volume status: '#{@current_resource.state}'."
          Chef::Log.info "Volume still attached to '#{@current_resource.device}'." unless @current_resource.device.nil?
          Chef::Log.info "Detach the volume using 'detach' action before attempting to delete."
          return
        end

        Chef::Log.info "Deleting volume '#{@current_resource.name}'..."
        status = delete_volume(@current_resource.volume_id)

        # Set device in node variable to nil after successfully deleting the volume
        delete_device_hash
        @new_resource.updated_by_last_action(true)
        if status
          Chef::Log.info " Successfully deleted volume '#{@current_resource.name}'"
        else
          Chef::Log.info " Volume '#{@current_resource.name}' was not deleted."
        end
      end

      # Attaches a volume to a device.
      #
      def action_attach
        # If volume is not created or already attached, do nothing
        if @current_resource.state.nil?
          Chef::Log.info "Device '#{@current_resource.name}' does not exist." +
            " This device may have been deleted or never been created."
          return
        elsif @current_resource.state == "in-use"
          msg = "Volume '#{@current_resource.name}' is already attached"
          msg << " to '#{@current_resource.device}'" unless @current_resource.device.nil?
          Chef::Log.info msg
          return
        end

        Chef::Log.info "Attaching volume '#{@current_resource.name}'..."

        attached_device = nil
        get_next_devices(1, device_letter_exclusions).map! do |device|
          attached_device = attach_volume(@current_resource.volume_id, device)
        end
        @current_resource.device = attached_device
        volume = find_volumes(:resource_uid => @current_resource.volume_id).first
        @current_resource.state = volume.show.status

        # Store all information in node variable
        save_device_hash
        @new_resource.updated_by_last_action(true)
        Chef::Log.info "Volume '#{@current_resource.name}' successfully attached to '#{attached_device}'"
      end

      # Detaches a volume from the device.
      #
      def action_detach
        # If volume is not available or not attached, do nothing
        if @current_resource.state.nil?
          Chef::Log.info "Device '#{@current_resource.name}' does not exist."
          Chef::Log.info "This device may have been deleted or never been created."
          return
        elsif @current_resource.state != "in-use"
          Chef::Log.info "Volume '#{@current_resource.name}' is not attached."
          Chef::Log.info "Volume status: '#{@current_resource.state}'."
          return
        end

        Chef::Log.info "Detaching volume '#{@current_resource.name}'..."

        # Use volume name for detaching. 'device' parameter for volume_attachment
        # cannot be trusted for API 1.5 and will be deprecated.
        detach_volume(@current_resource.volume_id)
        @current_resource.device = nil
        volume = find_volumes(:resource_uid => @current_resource.volume_id).first
        @current_resource.state = volume.show.status

        # Store all information in node variable
        save_device_hash
        @new_resource.updated_by_last_action(true)
        Chef::Log.info "Volume '#{@current_resource.name}' successfully detached."
      end

      # Creates a snapshot of the specified volume.
      #
      def action_snapshot
        if @current_resource.state.nil?
          Chef::Log.info "Device '#{@current_resource.name}' does not exist."
          Chef::Log.info "This device may have been deleted or never been created."
          return
        end

        Chef::Log.info "Creating snapshot of volume '#{@current_resource.name}'..."

        snapshot_name = @current_resource.name
        snapshot_name = @new_resource.snapshot_name if @new_resource.snapshot_name
        snapshot = create_volume_snapshot(snapshot_name, @current_resource.volume_id)

        # Store all information in node variable
        save_device_hash
        Chef::Log.info "Snapshot of volume '#{@current_resource.name}' successfully created."
        Chef::Log.info "Snapshot name: '#{snapshot.name}', ID: '#{snapshot.resource_uid}'"
      end

      # Deletes old snapshots that exceeds the maximum snapshots limit for the specified volume.
      #
      def action_cleanup
        if @current_resource.state.nil?
          Chef::Log.info "Device '#{@current_resource.name}' does not exist."
          Chef::Log.info "This device may have been deleted or never been created."
          return
        end

        # If user provides a value for max_snapshots use that or else use value
        # in the node.
        max_snapshots = @current_resource.max_snapshots
        max_snapshots = @new_resource.max_snapshots if @new_resource.max_snapshots
        num_snaps_deleted = cleanup_snapshots(@current_resource.volume_id, max_snapshots)

        # Store all information in node variable
        save_device_hash
        if num_snaps_deleted > 0
          Chef::Log.info "A total of #{num_snaps_deleted} snapshots were deleted."
        else
          Chef::Log.info "No snapshots were deleted."
        end
      end

    private

      # Removes the device hash from the node variable.
      #
      def delete_device_hash
        node.set['rightscale_volume'][@current_resource.name] = nil
      end

      # Saves device hash to the node variable.
      #
      def save_device_hash
        node.set['rightscale_volume'][@current_resource.name] ||= {}
        node.set['rightscale_volume'][@current_resource.name]['size'] = @current_resource.size
        node.set['rightscale_volume'][@current_resource.name]['volume_id'] = @current_resource.volume_id
        node.set['rightscale_volume'][@current_resource.name]['device'] = @current_resource.device
        node.set['rightscale_volume'][@current_resource.name]['description'] = @current_resource.description
        node.set['rightscale_volume'][@current_resource.name]['state'] = @current_resource.state
        node.set['rightscale_volume'][@current_resource.name]['max_snapshots'] = @current_resource.max_snapshots
      end

      # Initializes API client for handling API 1.5 calls.
      #
      # @param options [Hash] the optional parameters to the client
      #
      # @return [RightApi::Client] the RightAPI client instance
      #
      def initialize_api_client(options = {})
        # Require gems in initialize
        # We do it this way because the chef converge phase errors out due to
        # unavailability of these gems. These gems are only installed in the
        # network_storage_device::default recipe.
        require_gems

        require "/var/spool/cloud/user-data.rb"
        account_id, instance_token = ENV["RS_API_TOKEN"].split(":")
        api_url = "https://#{ENV["RS_SERVER"]}"
        options = {
          :account_id => account_id,
          :instance_token => instance_token,
          :api_url => api_url
        }.merge options

        client = RightApi::Client.new(options)
        client.log(Chef::Log.logger)
        client
      end

      # Workaround to require gems during RightAPI::Client initialization so that
      # the chef converge phase does not error due to unavailability of gems.
      # Error msg: error occurred line 31 of
      # /opt/rightscale/sandbox/lib/ruby/site_ruby/1.8/rubygems/custom_require.rb
      #
      # @raise [LoadError] if gems were not successfully loaded.
      def require_gems
        begin
          require "right_api_client"
          require "timeout"
        rescue LoadError => e
          msg = "Required gems were not loaded."
          msg << " Please run 'rightscale_volume::default' recipe to install these gems"
          display_exception(e, msg)
          raise e
        end
      end

      # Creates a new volume.
      #
      # @param name [String] the volume name
      # @param size [String] the volume size
      # @param description [String] the volume description
      # @param options [Hash] the optional parameters for creating volume
      #
      # @return [RightApi::ResourceDetail] the created volume
      #
      # @raise [RuntimeError] if volume size is less than 100 GB for Rackspace Open Cloud
      # @raise [RuntimeError] if no snapshots were found in the cloud with the given snapshot ID
      # @raise [RuntimeError] if the volume creation is unsuccessful
      # @raise [Timeout::Error] if volume creation takes longer than the timeout value
      #
      def create_volume(name, size, description = "", snapshot_id = nil, options = {})
        if (size < 100 && node[:cloud][:provider] == "rackspace-ng")
          raise "Minimum volume size supported by this cloud is 100 GB."
        end

        # Set required parameters
        params = {
          :volume => {
            :name => name,
            :size => size.to_s,
          }
        }

        instance = @api_client.get_instance
        datacenter_href = instance.links.detect { |link| link["rel"] == "datacenter" }
        params[:volume][:datacenter_href] = datacenter_href["href"] if datacenter_href

        volume_type_href = get_volume_type_href(node[:cloud][:provider], size, options)
        params[:volume][:volume_type_href] = volume_type_href unless volume_type_href.nil?

        # If description parameter is nill or empty do not pass it to the API
        params[:volume][:description] = description unless (description.nil? || description.empty?)

        # If snapshot_id is provided in the arguments, find the snapshot
        # and create the volume from the snapshot found
        unless snapshot_id.nil?
          snapshot = @api_client.volume_snapshots.index(:filter => ["resource_uid==#{snapshot_id}"]).first
          if snapshot.nil?
            raise "No snapshots found with snapshot ID '#{snapshot_id}'"
          else
            Chef::Log.info "Snapshot found with snapshot ID '#{snapshot_id}'"
            Chef::Log.info "Snapshot name - '#{snapshot.show.name}' Snapshot state - '#{snapshot.show.state}'"
            params[:parent_volume_snapshot_href] = snapshot.href
          end
        end

        Chef::Log.info "Requesting volume creation with params = #{params.inspect}"

        # Create volume and wait until the volume becomes "available" or "provisioned" (in azure)
        created_volume = nil
        Timeout::timeout(@current_resource.timeout * 60) do
          created_volume = @api_client.volumes.create(params)

          # Wait until the volume is succesfully created. A volume is said to be created
          # if volume status is "available" or "provisioned" (in cloudstack and azure).
          name = created_volume.show.name
          status = created_volume.show.status
          while status != "available" && status != "provisioned"
            Chef::Log.info "Waiting for volume '#{name}' to create... Current status is '#{status}'"
            raise "Creation of volume has failed." if status == "failed"
            sleep 2
            status = created_volume.show.status
          end
        end

        created_volume.show
      end

      # Gets href of a volume_type.
      #
      # @param cloud [Symbol] the cloud which supports volume types
      # @param size [Integer] the volume size (used by CloudStack to select appropriate volume type)
      # @param options [Hash] the optional paramters required to choose volume type
      #
      # @return [String, nil] the volume type href
      #
      # @raise [RuntimeError] if the volume type could not be found for the requested size (on CloudStack)
      #
      def get_volume_type_href(cloud, size, options = {})
        case cloud
        when "rackspace-ng"
          # Rackspace Open Cloud offers two types of devices - SATA and SSD
          volume_types = @api_client.volume_types.index
          volume_type = volume_types.detect { |type| type.name == options[:volume_type] }
          volume_type.href

        when "cloudstack"
          # CloudStack has the concept of a "custom" disk offering
          # Anything that is not a custom type is a fixed size.
          # If there is not a custom type, we will use the closest size which is
          # greater than or equal to the requested size.
          # If there are multiple custom volume types or multiple volume types
          # with the closest size, the one with the greatest resource_uid will
          # be used.
          # If the resource_uid is non-numeric (e.g. a UUID), the first returned
          # valid volume type will be used.
          volume_types = @api_client.volume_types.index
          custom_volume_types = volume_types.select { |type| type.size.to_i == 0 }

          if custom_volume_types.empty?
            volume_types.reject! { |type| type.size.to_i < size }
            minimum_size = volume_types.map { |type| type.size.to_i }.min
            volume_types.reject! { |type| type.size.to_i != minimum_size }
          else
            volume_types = custom_volume_types
          end

          if volume_types.empty?
            raise "Could not find a volume type that is large enough for #{size}"
          elsif volume_types.size == 1
            volume_type = volume_types.first
          elsif volume_types.first.resource_uid =~ /^[0-9]+$/
            Chef::Log.info "Found multiple valid volume types"
            Chef::Log.info "Using the volume type with the greatest numeric resource_uid"
            volume_type = volume_types.max_by { |type| type.resource_uid.to_i }
          else
            Chef::Log.info "Found multiple valid volume types"
            Chef::Log.info "Using the first returned valid volume type"
            volume_type = volume_types.first
          end

          if volume_type.size.to_i == 0
            Chef::Log.info "Found volume type that supports custom sizes:" +
              " #{volume_type.name} (#{volume_type.resource_uid})"
          else
            Chef::Log.info "Did not find volume type that supports custom sizes"
            Chef::Log.info "Using closest volume type: #{volume_type.name}" +
              " (#{volume_type.resource_uid}) which is #{volume_type.size} GB"
          end

          volume_type.href
        else
          nil
        end
      end

      # Deletes volume specified by resource UID.
      #
      # @param volume_id [String] the resource UID of the volume to be deleted
      #
      # @result [Boolean] status of volume deletion
      #
      # @raise [RightApi::Exceptions::ApiException] if volume destroy fails
      # @raise [Timeout:Error] if the volume deletion takes longer than the time out value
      #
      def delete_volume(volume_id)
        # Get volume by Resource UID
        volume = find_volumes(:resource_uid => volume_id).first

        # Rescue 422 errors with following error message "Volume still has 'n'
        # dependent snapshots" and add warning statements to indicate volume
        # deletion failure. This is a workaround for Rackspace Open Cloud
        # limitation where a volume cannot be destroyed if it has dependent
        # snapshots.
        Timeout::timeout(@current_resource.timeout * 60) do
          begin
            Chef::Log.info "Performing volume destroy..."
            volume.destroy
          rescue RightApi::Exceptions::ApiException => e
            http_code = e.message.match("HTTP Code: ([0-9]+)")[1]
            if http_code == "422" && e.message =~ /Volume still has \d+ dependent snapshots/
              Chef::Log.warn "#{e.message}. Cannot destroy volume #{volume.show.name}"
              false
            else
              raise e
            end
          end
        end
        true
      end

      # Attaches a volume to a device.
      #
      # @param volume_id [String] the resource UID of the volume to be attached
      # @param device [String] the device to which the volume must be attached
      #
      # @return [String] the device to which volume actually attached
      #
      # @raise [RestClient::Exception] if volume attachment fails
      # @raise [Timeout:Error] if the volume attach takes longer than the time out value
      #
      def attach_volume(volume_id, device)
        # Get volume by Resource UID
        volume = find_volumes(:resource_uid => volume_id).first

        # Set required paramters
        params = {
          :volume_attachment => {
            :volume_href => volume.show.href,
            :instance_href => instance_href,
            :device => device
          }
        }

        # use the lowest available LUN if we are on Azure/HyperV/VirtualPC
        hypervisor = node[:virtualization][:system] || node[:virtualization][:emulator]
        if hypervisor == "virtualpc"
          luns = attached_devices.map { |attached_device| attached_device.to_i }.to_set
          lun = 0
          params[:volume_attachment][:device] = loop do
            break lun unless luns.include? lun
            lun += 1
          end
        end

        current_devices = get_current_devices

        Chef::Log.info "Request volume attachment. params = #{params.inspect}"

        Timeout::timeout(@current_resource.timeout * 60) do
          begin
            attachment = @api_client.volume_attachments.create(params)
          rescue RestClient::Exception => e
            if e.http_code == 504
              Chef::Log.info "Timeout creating attachment - #{e.message}, retrying..."
              sleep 2
              retry
            end
            display_exception(e, "volume_attachments.create(#{params.inspect})")
            raise e
          end

          # Wait for volume to attach and become "in-use"
          begin
            name = volume.show.name
            status = volume.show.status
            state = attachment.show.state
            while status != "in-use" && state != "attached"
              Chef::Log.info "Waiting for volume '#{name}' to attach..."
              Chef::Log.info "Volume Status: #{status}, Attachment State: #{state}"
              sleep 2
              status = volume.show.status
              state = attachment.show.state
            end
          rescue RestClient::Exception => e
            if e.http_code == 504
              Chef::Log.info "Timeout waiting for attachment - #{e.message}, retrying..."
              sleep 2
              retry
            end
            display_exception(e, "#{e.message}")
            raise e
          end
        end

        # Determine the actual device name
        actual_device = (Set.new(get_current_devices) - current_devices).first
        Chef::Log.info "Device = #{device}, Actual_device = #{actual_device}" unless device == actual_device
        actual_device
      end

      # Finds volumes using the given filters.
      #
      # @param fliters [Hash] the filters to find the volume
      #
      # @return [<RightApi::Client::Resource>Array] the volumes found
      #
      def find_volumes(filters = {})
        @api_client.volumes.index(:filter => build_filters(filters))
      end

      # Builds a filters array in the format required by the RightScale API.
      #
      # @param filters [Hash<String, Object>] the filters as name, filter pairs
      #
      # @return [Array<String>] the filters as strings
      #
      def build_filters(filters)
        filters.map do |name, filter|
          case filter.to_s
          when /^(!|<>)(.*)$/
            operator = "<>"
            filter = $2
          when /^(==)?(.*)$/
            operator = "=="
            filter = $2
          end
          "#{name}#{operator}#{filter}"
        end
      end

      # Gets the devices to which the volumes are attached.
      #
      # @return [Array] devices to which the volumes are attached
      #
      def attached_devices
        volume_attachments.map { |attachment| attachment.show.device }
      end

      # Find the volume attachments on an instance using the given filters.
      #
      # @param filters [Hash] the filters to find volume attachments
      #
      # @return [RightApi::Resources] the volume attachments
      #
      def volume_attachments(filters = {})
        filter = ["instance_href==#{instance_href}"] + build_filters(filters)
        @api_client.volume_attachments.index(:filter => filter).reject do |attachment|
          attachment.show.device.include? "unknown"
        end
      end

      # Detaches a volume from the device
      #
      # @param volume_id [String] the resource UID of the volume to be detached
      #
      # @raise [Timeout::Error] if detaching volumes take longer than the time out value
      #
      def detach_volume(volume_id)
        Chef::Log.info "Preparing for volume detach"
        volume = find_volumes(:resource_uid => volume_id).first
        attachments = volume_attachments(:volume_href => volume.href)

        attachments.map do |attachment|
          volume = attachment.volume
          status = volume.show.status
          state = attachment.show.state
          name = volume.show.name
          Chef::Log.info "Volume staus: '#{status}', Attachment state: '#{state}'"

          Chef::Log.info "Performing volume detach..."
          Timeout::timeout(@current_resource.timeout * 60) do
            attachment.destroy
            while ((status = volume.show.status) == "in-use")
              Chef::Log.info "Waiting for volume '#{name}' to detach... Status is '#{status}'"
              sleep 2
            end
          end
          volume
        end
      end

      # Creates a snapshot of a given volume.
      #
      # @param snapshot_name [String] the name of the snapshot to be created
      # @param volume_id [String] the resource UID of the volume
      #
      # @return [RightApi::ResourceDetail] the snapshot created from the volume
      #
      # @raise [RuntimeError] if snapshot creation failed
      # @raise [Timeout::Error] if snapshot creation takes longer than the time out value
      #
      def create_volume_snapshot(snapshot_name, volume_id)
        Chef::Log.info "Preparing for volume snapshot..."

        volume = find_volumes(:resource_uid => volume_id).first
        params = {
          :volume_snapshot => {
            :name => snapshot_name,
            :description => volume.show.description,
            :parent_volume_href => volume.href
          }
        }

        Chef::Log.info "Performing volume snapshot..."
        snapshot = nil
        Timeout::timeout(@current_resource.timeout * 60) do
          snapshot = @api_client.volume_snapshots.create(params)
          name = snapshot.show.name
          while ((state = snapshot.show.state) == "pending")
            Chef::Log.info "Waiting for snapshot '#{name}' to create... State is '#{state}'"
            raise "Snapshot creation failed!" if state == "failed"
            sleep 2
          end
        end
        snapshot.show
      end

      # Deletes old snapshots of a specified volume that exceeds the maximum number of snapshots
      # to keep for that volume.
      #
      # @param volume_id [String] the resoure UID of the volume
      # @param max_snapshots_to_keep [Integer] the maximum number of snapshots to keep for a volume
      #
      # @return [Integer] the number of snapshots actually deleted
      #
      # @raise [Timeout::Error] if snapshot deletion takes longer than the time out value
      #
      def cleanup_snapshots(volume_id, max_snapshots_to_keep)
        volume = find_volumes(:resource_uid => volume_id).first

        # Find all "available" or "failed" snapshots created from specified
        # volume. Snapshots found are sorted from oldest to latest.
        available_snapshots = @api_client.volume_snapshots.index(:filter => ["parent_volume_href==#{volume.href}"])
        available_snapshots = available_snapshots.sort_by { |snapshot| snapshot.show.updated_at }

        num_deleted = 0
        num_available_snapshots = available_snapshots.length
        # If number of available snapshots less than or equal to maximum number
        # of snapshots to keep, no need to delete any snapshot.
        # Else, delete the oldest snapshots that exceeds maximum number of
        # snapshots to keep.
        if num_available_snapshots <= max_snapshots_to_keep
          Chef::Log.info "Number of available snapshots (#{num_available_snapshots}) is less than or equal to maximum" +
            " number of snapshots to keep (#{max_snapshots_to_keep})."
          Chef::Log.info  "No snapshots were deleted."

        else
          num_snapshots_to_delete = num_available_snapshots - max_snapshots_to_keep

          available_snapshots.each do |snapshot|
            # End condition for this loop
            break if num_deleted == num_snapshots_to_delete

            # Skip over snapshots that are not available for deletion.
            state = snapshot.show.state
            if state == "pending"
              Chef::Log.info "Snapshot #{snapshot.show.name} (ID:#{snapshot.show.resource_uid})" +
                " is not available for deletion. Snapshot state is '#{state}'"
              next
            end

            # Delete snapshot if they are available
            Chef::Log.info "Deleting snapshot '#{snapshot.show.name} (ID: #{snapshot.show.resource_uid})'..."
            Timeout::timeout(@current_resource.timeout * 60) do
              snapshot.destroy
            end
            num_deleted = num_deleted + 1
          end
        end
        num_deleted
      end

      # Gets the instance href.
      #
      # @return [String] the instance href.
      #
      def instance_href
        @instance_href ||= @api_client.get_instance.href
      end

      # Attempts to display any http response related information about the
      # exception and simply inspect the exception if none is available.
      #
      # @param e [Exception] the exception which needs to displayed and inspected.
      # @param display_name [String] optional display name to print custom information.
      #
      def display_exception(e, display_name = nil)
        Chef::Log.info "CAUGHT EXCEPTION in: #{display_name}"
        Chef::Log.info e.inspect
        puts e.backtrace
        if e.respond_to?(:response)
          Chef::Log.info e.response
          if e.response.respond_to?(:body)
            Chef::Log.info "RESPONSE BODY: #{e.response.body}"
          end
        end
      end

      # Gets all supported devices from /proc/partitions.
      #
      # @return [Array] the devices list.
      #
      def get_current_devices
        partitions = IO.readlines("/proc/partitions").drop(2).map do |line|
          line.chomp.split.last
        end
        partitions = partitions.reject { |partition| partition =~ /^dm-\d/ }

        devices = partitions.select { |partition| partition =~ /[a-z]$/ }
        devices = devices.sort.map { |device| "/dev/#{device}" }
        if devices.empty?
          devices = partitions.select { |partition| partition =~ /[0-9]$/ }
          devices = devices.sort.map { |device| "/dev/#{device}" }
        end
        devices
      end

      # Obtains next available devices.
      #
      # @param count [Integer] the number of devices
      # @param exclusions [Array] the devices to exclude
      #
      # @return [Array] the available devices
      #
      # @raise [RuntimeError] if the partition is unknown
      #
      def get_next_devices(count, exclusions = [])
        partitions = get_current_devices

        # The AWS EBS documentation recommends using /dev/sd[f-p] for attaching volumes.
        #
        # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-attaching-volume.html
        #
        if node[:cloud][:provider] == "ec2" && partitions.last =~ /^\/dev\/(s|xv)d[a-d][0-9]*$/
          partitions << "/dev/#{$1}de"
        end

        devices = []
        if partitions.first =~ /^\/dev\/([a-z]+d)[a-z]+$/
          type = $1

          if node[:cloud][:provider] == 'ec2' && type == 'hd'
            # This is probably HVM
            hvm = true
            # Root device is /dev/hda on HVM images, but volumes are xvd in /proc/partitions,
            # but can be referenced as sd also (mount shows sd) - PS
            type.sub!('hd','xvd')
          end

          partitions.select do |partition|
            partition =~ /^\/dev\/#{type}[a-z]+$/
          end.last =~ /^\/dev\/#{type}([a-z]+)$/

          if hvm
            # This is a HVM image, need to start at sdf at least
            letters = (['e', $1].max .. 'zzz')
          else
            letters = ($1 .. 'zzz')
          end
          devices = letters.select do |letter|
            letter != letters.first && !exclusions.include?(letter) && count != -1 && (count -= 1) != -1
          end
        elsif partitions.first =~ /^\/dev\/([a-z]+d[a-z]*)\d+$/
          type = $1
          devices = partitions.select do |partition|
            partition =~ /^\/dev\/#{type}\d+$/
          end.last =~ /^\/dev\/#{type}(\d+)$/
          number = $1.to_i
          (number + 1 .. number + count)
        else
          raise "unknown partition/device name: #{partitions.first}"
        end
        devices.map! { |letter| "/dev/#{type}#{letter}" }

        devices
      end

      # Returns a list of device exclusions due to some hypervisors having "holes" in their attachable device list.
      #
      # @return [Array] the device exclusions
      #
      def device_letter_exclusions
        exclusions = []
        # /dev/xvdd is assigned to the cdrom device eg., xentools iso (xe-guest-utilities)
        # that is likely a xenserver-ism
        exclusions = ["d"] if node[:cloud][:provider] == "cloudstack"
        exclusions
      end

      # Scans for volume attachments.
      #
      def scan_for_attachments
        # vmware/esx requires the following "hack" to make OS/Linux aware of device
        # Check for /sys/class/scsi_host/host0/scan if need to run
        if ::File.exist?("/sys/class/scsi_host/host0/scan")
          cmd = Mixlib::ShellOut.new("echo '- - -' > /sys/class/scsi_host/host0/scan")
          cmd.run_command
          sleep 5
        end
      end
    end
  end
end
