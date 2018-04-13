#!/usr/local/bin/ruby
# frozen_string_literal: true

class CAdvisorMetricsAPIClient
    
            require 'json'
            require 'logger'
            require 'net/http'
            require 'net/https'
            require 'uri'
            require 'date'
    
            require_relative 'oms_common'
            require_relative 'KubernetesApiClient'
    
            @LogPath = "/var/opt/microsoft/docker-cimprov/log/kubernetes_perf_log.txt"
            @Log = Logger.new(@LogPath, 2, 10*1048576) #keep last 2 files, max log file size = 10M
            @@rxBytesLast = nil
            @@rxBytesTimeLast = nil
            @@txBytesLast = nil
            @@txBytesTimeLast = nil
    
            def initialize
            end
    
            class << self
                def getSummaryStatsFromCAdvisor()
                    headers = {}
                    response = nil
                    @Log.info 'Getting CAdvisor Uri'
                    begin
                        cAdvisorUri = getCAdvisorUri()
                        if !cAdvisorUri.nil?
                            uri = URI.parse(cAdvisorUri)
                            http = Net::HTTP.new(uri.host, uri.port)
                            http.use_ssl = false
                                
                            cAdvisorApiRequest = Net::HTTP::Get.new(uri.request_uri)
                            response = http.request(cAdvisorApiRequest)
                            @Log.info "Got response code #{response.code} from #{uri.request_uri}"
                        end
                    rescue => error
                        @Log.warn("CAdvisor api request failed: #{error}")
                    end
                    return response
                end
    
                def getCAdvisorUri()
                    begin
                        defaultHost = "http://localhost:10255"
                        relativeUri = "/stats/summary"
                        nodeIP = ENV['NODE_IP']
                        if !nodeIP.nil?
                            @Log.info("Using #{nodeIP + relativeUri} for CAdvisor Uri")
                            return "http://#{nodeIP}:10255" + relativeUri
                        else
                            @Log.warn ("NODE_IP environment variable not set. Using default as : #{defaultHost + relativeUri} ")
                            return defaultHost + relativeUri
                        end
                    end
                end
    
                def getMetrics()
                    metricDataItems = []
                    begin
                        hostName = (OMS::Common.get_hostname)
                        metricInfo = JSON.parse(getSummaryStatsFromCAdvisor().body)
                        metricDataItems.concat(getContainerCpuMetricItems(metricInfo, hostName, "usageNanoCores","cpuUsageNanoCores"))
                        #<ToDo> Remove memoryUsageBytes once queries use workinset and rss
                        metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "rssBytes", "memoryUsageBytes"))
                        metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "workingSetBytes", "memoryWorkingSetBytes"))
                        metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "rssBytes", "memoryRssBytes"))
                        metricDataItems.concat(getContainerStartTimeMetricItems(metricInfo, hostName, "restartTimeEpoch"))

                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "cpu", "usageNanoCores", "cpuUsageNanoCores"))
                        #<ToDo> Remove memoryUsageBytes once queries use workinset and rss
                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "rssBytes", "memoryUsageBytes"))
                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "workingSetBytes", "memoryWorkingSetBytes"))
                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "rssBytes", "memoryRssBytes"))
                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "network", "rxBytes", "networkRxBytes"))
                        metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "network", "txBytes", "networkTxBytes"))
                        metricDataItems.push(getNodeLastRebootTimeMetric(metricInfo, hostName, "restartTimeEpoch"))
                        
                        networkRxRate = getNodeMetricItemRate(metricInfo, hostName, "network", "rxBytes", "networkRxBytesPerSec")
                        if networkRxRate && !networkRxRate.empty? && !networkRxRate.nil?
                            metricDataItems.push(networkRxRate)
                        end
                        networkTxRate = getNodeMetricItemRate(metricInfo, hostName, "network", "txBytes", "networkTxBytesPerSec")
                        if networkTxRate && !networkTxRate.empty? && !networkTxRate.nil?
                            metricDataItems.push(networkTxRate)
                        end
                        
                        
                        rescue => error
                        @Log.warn("getContainerMetrics failed: #{error}")
                        return metricDataItems
                    end
                    return metricDataItems
                end

                def getContainerCpuMetricItems(metricJSON, hostName, cpuMetricNameToCollect, metricNametoReturn)
                    metricItems = []
                    clusterId = KubernetesApiClient.getClusterId
                    begin
                        metricInfo = metricJSON
                        metricInfo['pods'].each do |pod|
                            podUid = pod['podRef']['uid']
                            if (!pod['containers'].nil?)
                                pod['containers'].each do |container|
                                    #cpu metric
                                    containerName = container['name']
                                    metricValue = container['cpu'][cpuMetricNameToCollect]
                                    metricTime = container['cpu']['time']
                                    metricItem = {}
                                    metricItem['DataItems'] = []
                                    
                                    metricProps = {}
                                    metricProps['Timestamp'] = metricTime
                                    metricProps['Host'] = hostName
                                    metricProps['ObjectName'] = "K8SContainer"
                                    metricProps['InstanceName'] = clusterId + "/" + podUid + "/" + containerName
                                    
                                    metricProps['Collections'] = []
                                    metricCollections = {}
                                    metricCollections['CounterName'] = metricNametoReturn
                                    metricCollections['Value'] = metricValue

                                    metricProps['Collections'].push(metricCollections)
                                    metricItem['DataItems'].push(metricProps)
                                    metricItems.push(metricItem)
                                end
                            end
                        end
                        rescue => error
                        @Log.warn("getcontainerCpuMetricItems failed: #{error} for metric #{cpuMetricNameToCollect}")
                        return metricItems
                    end
                    return metricItems                       
                end

                def getContainerMemoryMetricItems(metricJSON, hostName, memoryMetricNameToCollect, metricNametoReturn)
                    metricItems = []
                    clusterId = KubernetesApiClient.getClusterId
                    begin
                        metricInfo = metricJSON
                        metricInfo['pods'].each do |pod|
                            podUid = pod['podRef']['uid']
                            if (!pod['containers'].nil?)
                                pod['containers'].each do |container|
                                    containerName = container['name']
                                    metricValue = container['memory'][memoryMetricNameToCollect]
                                    metricTime = container['memory']['time']
                                    
                                    metricItem = {}
                                    metricItem['DataItems'] = []
                                    
                                    metricProps = {}
                                    metricProps['Timestamp'] = metricTime
                                    metricProps['Host'] = hostName
                                    metricProps['ObjectName'] = "K8SContainer"
                                    metricProps['InstanceName'] = clusterId + "/" + podUid + "/" + containerName
                                    
                                    metricProps['Collections'] = []
                                    metricCollections = {}
                                    metricCollections['CounterName'] = metricNametoReturn
                                    metricCollections['Value'] = metricValue

                                    metricProps['Collections'].push(metricCollections)
                                    metricItem['DataItems'].push(metricProps)
                                    metricItems.push(metricItem)
                                end
                            end
                        end
                        rescue => error
                        @Log.warn("getcontainerMemoryMetricItems failed: #{error} for metric #{memoryMetricNameToCollect}")
                        @Log.warn metricJSON
                        return metricItems
                    end
                    return metricItems                      
                end

                def getNodeMetricItem(metricJSON, hostName, metricCategory, metricNameToCollect, metricNametoReturn)
                    metricItem = {}
                    clusterId = KubernetesApiClient.getClusterId
                    begin
                        metricInfo = metricJSON
                        node = metricInfo['node']
                        nodeName = node['nodeName']
                        
                        
                        metricValue = node[metricCategory][metricNameToCollect]
                        metricTime = node[metricCategory]['time']
                        
                        metricItem['DataItems'] = []
                        
                        metricProps = {}
                        metricProps['Timestamp'] = metricTime
                        metricProps['Host'] = hostName
                        metricProps['ObjectName'] = "K8SNode"
                        metricProps['InstanceName'] = clusterId + "/" + nodeName
                        
                        metricProps['Collections'] = []
                        metricCollections = {}
                        metricCollections['CounterName'] = metricNametoReturn
                        metricCollections['Value'] = metricValue

                        metricProps['Collections'].push(metricCollections)
                        metricItem['DataItems'].push(metricProps)
                        
                        rescue => error
                        @Log.warn("getNodeMetricItem failed: #{error} for metric #{metricNameToCollect}")
                        @Log.warn metricJSON
                        return metricItem
                    end
                    return metricItem                      
                end

                def getNodeMetricItemRate(metricJSON, hostName, metricCategory, metricNameToCollect, metricNametoReturn)
                    metricItem = {}
                    clusterId = KubernetesApiClient.getClusterId
                    begin
                        
                        metricInfo = metricJSON
                        node = metricInfo['node']
                        nodeName = node['nodeName']
                        
                        metricValue = node[metricCategory][metricNameToCollect]
                        metricTime = node[metricCategory]['time']

                        if !(metricNameToCollect == "rxBytes" || metricNameToCollect == "txBytes" )
                            @Log.warn("getNodeMetricItemRate : rateMetric is supported only for rxBytes & txBytes and not for #{metricNameToCollect}")
                            return nil
                        elsif metricNameToCollect == "rxBytes"
                            if @@rxBytesLast.nil? || @@rxBytesTimeLast.nil?
                                @@rxBytesLast = metricValue
                                @@rxBytesTimeLast = metricTime
                                return nil
                            else
                                metricValue = ((metricValue - @@rxBytesLast) * 1.0)/(DateTime.parse(metricTime).to_time - DateTime.parse(@@rxBytesTimeLast).to_time)
                            end
                        else
                            if @@txBytesLast.nil? || @@txBytesTimeLast.nil?
                                @@txBytesLast = metricValue
                                @@txBytesTimeLast = metricTime
                                return nil
                            else
                                metricValue = ((metricValue - @@txBytesLast) * 1.0)/(DateTime.parse(metricTime).to_time - DateTime.parse(@@txBytesTimeLast).to_time)
                            end
                        end
                        
                        metricItem['DataItems'] = []
                        
                        metricProps = {}
                        metricProps['Timestamp'] = metricTime
                        metricProps['Host'] = hostName
                        metricProps['ObjectName'] = "K8SNode"
                        metricProps['InstanceName'] = clusterId + "/" + nodeName
                        
                        metricProps['Collections'] = []
                        metricCollections = {}
                        metricCollections['CounterName'] = metricNametoReturn
                        metricCollections['Value'] = metricValue

                        metricProps['Collections'].push(metricCollections)
                        metricItem['DataItems'].push(metricProps)
                        
                        rescue => error
                        @Log.warn("getNodeMetricItemRate failed: #{error} for metric #{metricNameToCollect}")
                        @Log.warn metricJSON
                        return nil
                    end
                    return metricItem
                end

                def getNodeLastRebootTimeMetric(metricJSON, hostName, metricNametoReturn)
                    metricItem = {}
                    clusterId = KubernetesApiClient.getClusterId
                    
                    begin
                        metricInfo = metricJSON
                        node = metricInfo['node']
                        nodeName = node['nodeName']
                        
                        
                        metricValue = node['startTime']
                        metricTime = Time.now.utc.iso8601 #2018-01-30T19:36:14Z
                        
                        metricItem['DataItems'] = []
                        
                        metricProps = {}
                        metricProps['Timestamp'] = metricTime
                        metricProps['Host'] = hostName
                        metricProps['ObjectName'] = "K8SNode"
                        metricProps['InstanceName'] = clusterId + "/" + nodeName
                        
                        metricProps['Collections'] = []
                        metricCollections = {}
                        metricCollections['CounterName'] = metricNametoReturn
                        #metricCollections['Value'] = DateTime.parse(metricValue).to_time.to_i
                        #Try to read it from /proc/uptime
                        metricCollections['Value'] = DateTime.parse(metricTime).to_time.to_i - IO.read("/proc/uptime").split[0].to_f

                        metricProps['Collections'].push(metricCollections)
                        metricItem['DataItems'].push(metricProps)
                        
                        rescue => error
                        @Log.warn("getNodeLastRebootTimeMetric failed: #{error} ")
                        @Log.warn metricJSON
                        return metricItem
                    end
                    return metricItem                      
                end

                def getContainerStartTimeMetricItems(metricJSON, hostName, metricNametoReturn)
                    metricItems = []
                    clusterId = KubernetesApiClient.getClusterId
                    currentTime = Time.now.utc.iso8601 #2018-01-30T19:36:14Z
                    begin
                        metricInfo = metricJSON
                        metricInfo['pods'].each do |pod|
                            podUid = pod['podRef']['uid']
                            if (!pod['containers'].nil?)
                                pod['containers'].each do |container|
                                    containerName = container['name']
                                    metricValue = container['startTime']
                                    metricTime = currentTime
                                    
                                    metricItem = {}
                                    metricItem['DataItems'] = []
                                    
                                    metricProps = {}
                                    metricProps['Timestamp'] = metricTime
                                    metricProps['Host'] = hostName
                                    metricProps['ObjectName'] = "K8SContainer"
                                    metricProps['InstanceName'] = clusterId + "/" + podUid + "/" + containerName
                                    
                                    metricProps['Collections'] = []
                                    metricCollections = {}
                                    metricCollections['CounterName'] = metricNametoReturn
                                    metricCollections['Value'] = DateTime.parse(metricValue).to_time.to_i

                                    metricProps['Collections'].push(metricCollections)
                                    metricItem['DataItems'].push(metricProps)
                                    metricItems.push(metricItem)
                                end
                            end
                        end
                        rescue => error
                        @Log.warn("getContainerStartTimeMetric failed: #{error} for metric #{metricNametoReturn}")
                        @Log.warn metricJSON
                        return metricItems
                    end
                    return metricItems                       
                end
            end
        end
