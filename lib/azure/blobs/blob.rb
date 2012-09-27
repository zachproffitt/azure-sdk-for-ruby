#-------------------------------------------------------------------------
# Copyright 2012 Microsoft Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#--------------------------------------------------------------------------
require "nokogiri"
require "uri"
require "azure/core/error"
require "azure/blobs"
require "azure/blobs/uri"
require "digest/sha1"

module Azure
  module Blobs
    class Blob
      include Core::ErrorHandler

      # List of valid property names
      PROPERTIES = [
        "content-length",
        "content-type",
        "content-md5",
        "content-encoding",
        "content-language",
        "cache-control",
        "last-modified",
        "etag",
        "x-ms-lease-status",
        "x-ms-lease-time",
        "x-ms-lease-id",
        "x-ms-blob-sequence-number",
        "x-ms-snapshot"
      ].freeze

      # Public: Get/Set the Blob container
      attr_accessor :container

      # Public: Get the name of the Blob
      attr :name

      # Public: Get the Properties for the Blob as a Hash.
      #
      # Following are *Optional*
      # - "x-ms-blob-cache-control"    Modifies the cache control string for the blob.
      # - "x-ms-blob-content-type"     Sets the blob content type.
      # - "x-ms-blob-content-md5"      Sets the blob MD5 hash.
      # - "x-ms-blob-content-encoding" Sets the blob content encoding.
      # - "x-ms-blob-content-languag"  Sets the blob content language.
      #
      # Following may be *Required*
      # - "x-ms-lease-id"              Required if the blob has an active lease.
      #
      # Following properties only apply to Page Blobs.
      # - Optional "x-ms-blob-content-length" Resizes a page blob to the specified size.
      #   If the specified value is less than the current size of the blob, then all
      #   pages above the specified value are cleared.
      #
      # - "x-ms-sequence-number-action" Optional, but required if the x-ms-blob-sequence-number
      #   header is set for the request. Posible values: {max, update, increment}
      #
      # - "x-ms-blob-sequence-number" Optional, but required if the x-ms-sequence-number-action
      #   property is set to max or update.
      #
      # See: http://msdn.microsoft.com/en-us/library/windowsazure/ee691966
      attr :properties

      # Public: Get the Metadata of the blob as a Hash
      attr :metadata

      # Public: Get the Content of the blob
      attr :content

      # Public: Initialize a Blob from an XML node
      # (eg. as returned from an API response)
      #
      # node      - A Nokogiri::Node
      #
      # Returns a Blob
      def self.from_node(node)
        name = (node % "Name").text

        properties = (node / "Properties *").each_with_object({}) do |no, props|
          props[no.name] = no.text
        end

        metadata = (node / "Metadata *").each_with_object({}) do |no, meta|
          meta[no.name] = no.text
        end

        container_name = (node / "Url").text.split("/")[-2..-2].first
        container = Azure::Blobs::Container.new(container_name)

        new(name, container) do |blob|
          blob.metadata.replace(metadata)
          blob.properties.replace(properties)
          yield blob if block_given?
        end
      end

      # Public: Instantiate a blob from an error object
      #
      # error - An Azure::Core::Error
      #
      # Returns a Table
      def self.from_error(error)
        new(nil, nil, nil) do |blob|
          blob.error = error
        end
      end

      # Public: Initialize a Blob.
      #
      # name       - A String with the name of the Blob
      # container  - An Azure::Blobs::Container instance (optional)
      # content    - The content of the Blob (optional)
      # service    - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional) 
      def initialize(name, container=nil, content=nil, service=Azure::Blobs)
        @name = name
        @container = container
        @content = content
        @properties = {}
        @metadata = {}
        @service = service
        yield self if block_given?
      end

      # Public: The url of the Blob
      #
      # Returns a Blobs::URI
      def url
        Blobs::URI.blob(container.name, name)
      end

      # Public: Check equality between Blobs. Two instances of Blob are
      # equal if they have the same name and belong to the same 
      # container.
      #
      # other - A Blob instance to compare to
      #
      # Returns true when equal or false when not equal
      def ==(other)
        !container.nil? && container == other.container && name == other.name
      end

      # Public: Delete the Blob from the storage service. If the operation is
      # unsuccessful the Blob will be invalidated.
      #
      # Returns true on success or false on failure
      def delete
        @service.delete_blob(self)
      end

      # Public: Force a reload of the metadata for the Blob from the service.
      #
      # Returns the Hash of metadata
      def load_metadata!
        @service.load_blob_metadata(self)
      end

      # Public: Put the metadata for the Blob into the storage service.
      #
      # Returns true on success or false on failure
      def save_metadata!
        @service.save_blob_metadata(self)
      end

      # Public: Extracts metadata from a Hash of HTTP headers. 
      # Headers beginning with "x-ms-meta-" will be extracted. 
      # 
      # For example: 
      # "x-ms-meta-Name" => "Foo" is extracted as "Name" => "Foo"
      #
      # It also replaces the current metadata for the Blob with 
      # the extracted metadata.
      #
      # hash - A hash of String => String with HTTP header values.
      #
      # Returns a Hash with the extracted metadata
      def extract_metadata(hash)
        new_metadata = hash.each_with_object({}) do |(k,v), hash|
          if key = k[/^x-ms-meta-(.*)/, 1]
            hash[key] = v
          end
        end

        metadata.replace(new_metadata)
      end

      # Public: Put the properties for the Blob into the storage service
      #
      # headers - A Hash with user defined headers
      #
      # Returns true on success or false on failure
      def save_properties!(headers={})
        @service.save_blob_properties(self, headers)
      end

      # Public: Force a reload of properties for the Blob from the server
      #
      # headers - A Hash with user defined headers
      #
      # Returns a Hash with the Blob properties
      def load_properties!(headers={})
        @service.load_blob_properties(self, headers)
      end

      # Public: Extracts properties from a hash containing HTTP headers. This
      # replaces the properties of the Blob. Any headers that are
      # contained in PROPERTIES are extracted.
      #
      # hash - A hash of String => String with HTTP header values
      #
      # Returns a Hash with the extracted properties
      def extract_properties(hash)
        new_properties = hash.select do |key, _|
          PROPERTIES.include?(key)
        end
        new_properties.merge!("x-ms-lease-id" => lease_id) if lease_id
        properties.replace(new_properties)
      end

      # Public: Generate a Shared Access Signature that can be used to provide
      # anonymous access to the Blob
      #
      # permissions - A String with the permissions you want to grant on the
      #               Blob. Might contain any of "r", "w", "d", or "l" *in this
      #               order*.
      # to          - Either a Date, Time or duration in seconds.
      # from        - A Date or Time (if `to` is a duration in seconds, then
      #               this is ignored).
      # id          - An identifier (optional)
      # clock       - Dependency on Time (for calculations) may be injected (optional)
      # signature   - Dependency on SharedAccessSignature may be injected (optional)
      #
      # Examples:
      #
      #   # Valid for 10 minutes.
      #   blob.shared_access_signature("r", 10.minutes)
      #
      #   # Read until Christmas 2012.
      #   blob.shared_access_signature("r", Date.new(2012, 12, 25))
      #
      #   # Associate the signature with an access control policy:
      #   blob.shared_access_signature("r", 10.minutes, "policy-id")
      #
      # Returns a URL for the resource that includes the SAS.
      def shared_access_signature(permissions, to, from=nil, id=nil, clock=Time, signature=SharedAccessSignature)
        if to.respond_to?(:to_int)
          id, to, from = from, clock.now.utc + to, clock.now.utc
        end

        signature.new(permissions, from, to, id).url(self)
      end

      # Public: String identifying which type of resource this is (used to
      # generate shared access signatures).
      #
      # Returns the string "b".
      def resource_type
        "b"
      end

      # Public: Creates a snapshot of the Blob
      #
      # metadata  - A Hash representing Blob metadata as :name => value (optional)
      #
      # Returns an instance of Azure::Blobs::Snapshot
      def create_snapshot(metadata={})
        Azure::Blobs.create_snapshot(self, metadata)
      end

      # Public: Get the lease_id from the Blob properties
      def lease_id
        properties["x-ms-lease-id"]
      end
    end

    class Snapshot < Blob
      # Public: Return the Snapshot id (A datetime value from the x-ms-snapshot property)
      def id
        properties["x-ms-snapshot"]
      end

      # Public: Delete the Snapshot
      def delete
        @service.delete_snapshot(self)
      end

      # Public: Acquire a Lease ID for the Snapshot
      #
      # service - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional) 
      #
      # http://msdn.microsoft.com/en-us/library/windowsazure/ee691972
      def acquire_lease(service=Azure::Blobs)
        service.lease(@blob, :acquire)
      end

      # Public: Renew Lease ID for the Snapshot
      #
      # service - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional)
      #
      # http://msdn.microsoft.com/en-us/library/windowsazure/ee691972
      def renew_lease(service=Azure::Blobs)
        service.lease(@blob, :renew)
      end

      # Public: Release Lease ID for the Snapshot
      #
      # service - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional)
      #
      # http://msdn.microsoft.com/en-us/library/windowsazure/ee691972
      def release_lease(service=Azure::Blobs)
        service.lease(@blob, :release)
      end

      # Public: Break Lease ID for the Snapshot
      #
      # service - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional)
      #
      # http://msdn.microsoft.com/en-us/library/windowsazure/ee691972
      def break_lease(service=Azure::Blobs)
        service.lease(@blob, :break)
      end
    end

    class BlockBlob < Blob

      # Public: Get the content type for the BlockBlob
      attr :content_type

      # Public: Upload a file to the BlockBlob, overriding the content if it exists
      # Blob metadata and properties will also be sent.
      #
      # filename_or_stream - IO or String. The resource on the filesystem
      # content_type       - String. The content-type of the uploaded blob (optional)
      # byte_partition     - Integer. The size of the chunks to be uploaded (optional)
      #
      # service - A Blobs Service instance. Defaults to Azure::Blobs but may be injected (optional)
      #
      # Returns true on success or false on failure
      def update(filename_or_stream, content_type=nil, byte_partition=nil, service=Azure::Blobs)

        stream = filename_or_stream.is_a?(String) ? File.open(filename_or_stream) : filename_or_stream

        @content_type = content_type ||= "application/octet-stream"

        block_ids = service.update_block_blob_content(self, stream, byte_partition)

        if block_ids.any? && service.put_block_list(self, block_ids)
          stream.rewind
          @content = stream.read
          true
        else
          false
        end
      end
    end

    class PageBlob < Blob
      # Public: Sets the write range of the pages
      #
      # start_byte - Integer. The starting position 
      # end_byte   - Integer. The ending position 
      # stream     - IO or String. A content stream. The :content attribute will be set to this value.
      # 
      # Returns true on success or false on failure
      def update_range(start_byte, end_byte, stream)
        if Azure::Blobs.update_page_range(self, start_byte, end_byte, stream)
          @content = stream
          true
        else
          false
        end
      end

      # Public: Clear a range of pages
      #
      # start_byte - Integer. The starting position 
      # end_byte   - Integer. The ending position 
      # 
      # Returns true on success or false on failure
      def clear_range(start_byte, end_byte)
        Azure::Blobs.clear_page_range(self, start_byte, end_byte)
      end

      # Public: Get a range of pages
      #
      # start_byte - Integer. The starting position (optional)
      # end_byte   - Integer. The ending position (optional)
      # 
      # Returns true on success or false on failure
      def get_range(start_byte=nil, end_byte=nil)
        Azure::Blobs.get_page_range(self, start_byte, end_byte)
      end
    end
  end
end
