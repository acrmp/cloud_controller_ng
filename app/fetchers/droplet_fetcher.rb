module VCAP::CloudController
  class DropletFetcher
    def fetch(droplet_guid)
      droplet = DropletModel.where(guid: droplet_guid).first
      return nil if droplet.nil?

      org = droplet.space ? droplet.space.organization : nil

      [droplet, droplet.space, org]
    end
  end
end
