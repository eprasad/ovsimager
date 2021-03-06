require_relative 'utils'

module OVSImager
  class IPNetNS
    def initialize()
      @ns = exec_ip('netns').split(/\n/).map{|x| x.sub(/\s+\(id: \d+\)/, '')}
      @ifaces = {:root => parse_address(exec_ip('a'), :root)}
      links = parse_link(exec_ip('-d link'), :root)
      merge_link_type(@ifaces[:root], links)
      @ns.each {|ns|
        out = exec_ip("netns exec #{ns} ip a", true)
        @ifaces[ns] = parse_address(out, ns)
        out = exec_ip("netns exec #{ns} ip -d link", true)
        links = parse_link(out, ns)
        merge_link_type(@ifaces[ns], links)
      }
      find_veth_pair
    end

    def ns()
      @ns
    end

    def to_hash()
      @ifaces
    end

    def ifname_ns(iface)
      iface[:name] + (iface[:ns] == :root ? "" : ":" + iface[:ns].to_s)
    end

    def ifaces_hash()
      @ifaces.inject({}) {|h, (ns, v)| v.each {|i| h[ifname_ns(i)] = i}; h}
    end

    def ifaces_ary()
      @ifaces.inject([]) {|a, (ns, v)| v.each {|i| a[i[:id].to_i] = i}; a}
    end

    def exec_ip(args, root=false)
      Utils.execute("ip #{args}", root)
    end

    private
    def parse(out, args)
      out.split(/\n(?=[^ \s])/).map do |iface|
        if iface.match(/^(\d+):\s+(\S+?)(?:@(\S+))?:+/)
          params = {:id => $1, :name => $2}
          if $3 && $3[0,2] == 'if'
            params[:peerid] = $3.sub(/^if/, '')
          elsif $3 && $3 != 'NONE'
            params[:peer] = $3
          end
          yield params, iface, args
        else
          STDERR.puts "IPNetNS: parse error: #{iface}"
          {}
        end
      end
    end

    def parse_address(out, ns)
      parse(out, ns) do |params, iface, ns|
        params[:ns] = ns
        params[:mac] = $1 if iface.match(/link\/\w+ (\S+)/)
        [:inet, :inet6].each do |key|
          params[key] = iface.scan(/#{key.to_s} (\S+)/)
        end
        [:mtu, :state].each do |key|
          params[key] = $1 if iface.match(/#{key.to_s} (\S+)/)
        end
        params
      end
    end

    def parse_link(out, ns)
      parse(out, ns) do |params, iface, ns|
        params[:ns] = ns
        params[:mac] = $1 if iface.match(/link\/\w+ (\S+)/)
        params[:type] = (iface.split(/\n/)[2] || '').strip.split(/\s+/)[0]
        params
      end
    end

    def merge_link_type(ifaces, links)
      link_types = links.inject({}) {|h, link| h[link[:id]] = link[:type]; h}
      ifaces.each {|iface| iface[:type] = link_types[iface[:id]]}
    end

    def find_veth_pair()
      ifaces = ifaces_ary
      ifaces.each do |iface|
        next unless iface
        if iface[:type] == 'veth' && !iface[:peer] && iface[:peerid]
          peerid = iface[:peerid].to_i
          if ifaces[peerid] && ifaces[peerid][:peerid] == iface[:id]
            iface[:peer] = ifaces[peerid][:name]
            iface[:peerns] = ifaces[peerid][:ns]
            ifaces[peerid][:peer] = iface[:name]
            ifaces[peerid][:peerns] = iface[:ns]
          end
        elsif iface[:type] == 'veth' && !iface[:peer] && !iface[:peerid]
          if iface[:ns] == :root
            out = Utils::execute("ethtool -S #{iface[:name]}")
          else
            out = exec_ip("netns exec #{iface[:ns]} ethtool -S #{iface[:name]}", root=true)
          end
          if out.match /peer_ifindex: (\d+)/
            iface[:peer] = ifaces[$1.to_i][:name]
            iface[:peerns] = ifaces[$1.to_i][:ns]
            ifaces[$1.to_i][:peer] = iface[:name]
            ifaces[$1.to_i][:peerns] = iface[:ns]
          else
            STDERR.puts("Failed to lookup veth peer of '#{iface[:name]}'")
          end
        end
      end
    end
  end
end
