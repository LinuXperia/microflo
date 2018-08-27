### MicroFlo - Flow-Based Programming for microcontrollers
# Copyright (c) 2013 Jon Nordby <jononor@gmail.com>
# MicroFlo may be freely distributed under the MIT license
###

cmdFormat = require('./commandformat')
protocol = require './protocol'
util = require('./util')
Buffer = util.Buffer
fbp = require('fbp')

writeCmd = ->
  buf = arguments[0]
  offset = arguments[1]
  data = arguments[2]
  if typeof data == 'object' and data.length?
    # Buffer
    data.copy buf, offset
    return data.length
  else
    data = Array::slice.call(arguments, 2)
  i = 0
  while i < cmdFormat.commandSize
    # console.log(offset, data);
    if i < data.length
      buf.writeUInt8 data[i], offset + i
    else
      buf.writeUInt8 0, offset + i
    i++
  cmdFormat.commandSize

writeString = (buf, offset, string) ->
  i = 0
  while i < string.length
    buf[offset + i] = string.charCodeAt(i)
    i++
  string.length

writeNewCmd = () ->
  b = new Buffer cmdFormat.commandSize
  b.fill 0, 0, cmdFormat.commandSize
  args = Array.prototype.slice.call arguments
  args.unshift b, 0
  writeCmd.apply this, args
  return b

serializeError = (obj) ->
    info = cmdFormat.errors[obj.error] or cmdFormat.errors['Unknown']
    b = new Buffer(cmdFormat.commandSize-4)
    b.fill(0)
    b.writeUInt8 info.id, 0
    return { type: 'Error', data: b }

serializeData = (literal) ->
  dataSize = cmdFormat.commandSize-5
  # Null (bang)
  if not literal? or literal == 'null'
    b = Buffer.alloc dataSize
    b.fill(0)
    return { type: 'Void', data: b }
  # Integer
  value = parseInt(literal)
  if typeof value == 'number' and value % 1 == 0
    b = Buffer.alloc dataSize
    b.fill(0)
    b.writeInt32LE value, 0
    return { type: 'Integer', data: b }
  # Boolean
  isBool = literal == 'true' or literal == 'false'
  value = literal == 'true'
  if isBool
    b = Buffer.alloc dataSize
    b.fill(0)
    val = if value then 1 else 0
    b.writeInt8 val, 0
    return { type: 'Boolean', data: b }

  return null # not a plain value
  # TODO: handle floats

deserializeData = (buf, offset) ->
    type = nodeNameById cmdFormat.packetTypes, buf.readUInt8(offset)
    data = undefined
    if type == 'Boolean'
      data = if buf.readUInt8(offset+1) then true else false
    else if type == 'Void'
      data = null
    else if type == 'Integer' or type == 'Float'
      data = buf.readInt32LE(offset+1)
    else if type == 'Byte'
      data = buf.readUInt8(offset+1)
    else if type == 'Error'
      errno = buf.readUInt8(offset+1)
      type = nodeNameById cmdFormat.errors, errno
      info = cmdFormat.errors[type] or cmdFormat.errors['Unknown']
      data = { error: type, message: info.description }
    else if type == 'BracketStart' or type == 'BracketEnd'
      data = type
    else
      console.log 'Unknown data type in PacketSent: ', type
    return { type: type, data: data }

isError = (data) ->
    return data? and typeof data.error == 'string'

dataToCommandDescriptions = (data) ->
    # XXX: wrong way around, literal should call this, not
    if Array.isArray(data) or isError(data)
        literal = JSON.stringify data
#    else if typeof data == 'string'
#        literal = "\"#{data}\""
    else
        literal = data+''
    return dataLiteralToCommandDescriptions literal

# literal is a string, typically from a .FBP graph
dataLiteralToCommandDescriptions = (literal) ->
  commands = [] # [ { type: '', data: ?Buffer } ]
  literal = literal.replace('^"|"$', '')

  basic = serializeData literal
  if basic
    return [ basic ]

  # compound type / stream
  try
    value = JSON.parse(literal)
  catch err
    throw 'Unknown IIP data type for literal \'' + literal + '\' :' + err

  if Array.isArray value
    commands.push { type: "BracketStart" }
    for val in value
        subs = dataToCommandDescriptions val
        commands = commands.concat subs
    commands.push { type: "BracketEnd" }
    return commands
  else if isError value
    p = serializeError value
    return [ p ]

  throw 'Unknown IIP data type for literal \'' + literal + '\''

serializeCommands = (commands, tgt, tgtPort) ->
  buffers = []
  for cmd in commands
    type = cmdFormat.packetTypes[cmd.type].id
    header = new Buffer 5
    header.writeUInt8 0 # space for requestId
    header.writeInt8 cmdFormat.commands.SendPacket.id, 1
    header.writeUInt8 tgt, 2
    header.writeUInt8 tgtPort, 3
    header.writeUInt8 type, 4
    data = cmd.data
    if not data
        data = new Buffer cmdFormat.commandSize-header.length
        data.fill 0
    buffers.push header
    buffers.push data

  r = Buffer.concat buffers
  return r

dataLiteralToCommand = (literal, tgt, tgtPort) ->
  commands = dataLiteralToCommandDescriptions literal
  return serializeCommands commands, tgt, tgtPort

dataToCommand = (data, tgt, tgtPort) ->
  commands = dataToCommandDescriptions data
  return serializeCommands commands, tgt, tgtPort

findPort = (componentLib, graph, nodeName, portName) ->
  isOutput = false
  port = componentLib.inputPort(graph.processes[nodeName].component, portName)
  if !port
    port = componentLib.outputPort(graph.processes[nodeName].component, portName)
    isOutput = true
  {
    isOutput: isOutput
    port: port
  }

# outgoing communication
commands =
  graph: {}
  network: {}
  runtime: {}
  microflo: {}

commands.graph.addnode = (payload, buffer, index, componentLib) ->
  nodeName = payload.id
  componentName = payload.component
  comp = componentLib.getComponent(componentName)
  if typeof comp == 'undefined'
    throw new Error('Cannot find component: ' + componentName)

  # Add normal component
  parentId = undefined # subgraph not supported yet
  index += writeCmd(buffer, index, 0, cmdFormat.commands.CreateComponent.id, comp.id, parentId or 0)
  return index

commands.graph.removenode = (payload, buffer, index, componentLib, nodeMap) ->
  nodeName = payload.id
  nodeId = nodeMap[nodeName].id

  # Add normal component
  index += writeCmd(buffer, index, 0, cmdFormat.commands.RemoveNode.id, nodeId)
  return index

commands.graph.addedge = (payload, buffer, index, componentLib, nodeMap, componentMap) ->
  srcNode = payload.src.node
  tgtNode = payload.tgt.node
  srcPort = undefined
  tgtPort = undefined
  try
    srcComponent = componentMap[srcNode]
    tgtComponent = componentMap[tgtNode]
    srcPort = componentLib.outputPort(srcComponent, payload.src.port).id
    tgtPort = componentLib.inputPort(tgtComponent, payload.tgt.port).id
  catch err
    throw new Error "Could not connect: #{srcNode} #{payload.src.port} -> #{payload.tgt.port} #{tgtNode} : #{err}"
  if not tgtPort?
    throw new Error "Could not find target port #{tgtNode}(#{tgtComponent}) #{payload.tgt.port}"
  if not srcPort?
    throw new Error "Could not find source port #{srcNode}#{srcComponent} #{payload.src.port}"

  index += writeCmd(buffer, index, 0, cmdFormat.commands.ConnectNodes.id, nodeMap[srcNode].id, nodeMap[tgtNode].id, srcPort, tgtPort)  
  return index

commands.graph.removeedge = (payload, buffer, index, componentLib, nodeMap, componentMap) ->
  srcNode = payload.src.node
  tgtNode = payload.tgt.node
  srcPort = undefined
  tgtPort = undefined
  try
    srcComponent = componentMap[srcNode]
    tgtComponent = componentMap[tgtNode]
    srcPort = componentLib.outputPort(srcComponent, payload.src.port).id
    tgtPort = componentLib.inputPort(tgtComponent, payload.tgt.port).id
  catch err
    throw new Error "Could not disconnect: #{srcNode} #{payload.src.port} -> #{payload.tgt.port} #{tgtNode} : #{err}"
  if not tgtPort?
    throw new Error "Could not find target port #{tgtNode}(#{tgtComponent}) #{payload.tgt.port}"
  if not srcPort?
    throw new Error "Could not find source port #{srcNode}#{srcComponent} #{payload.src.port}"

  index += writeCmd(buffer, index, 0, cmdFormat.commands.DisconnectNodes.id, nodeMap[srcNode].id, nodeMap[tgtNode].id, srcPort, tgtPort)
  return index

# TODO: support graph.removeinitial
commands.graph.addinitial = (payload, buffer, index, componentLib, nodeMap, componentMap) ->
  tgtNode = payload.tgt.node
  tgtPort = undefined
  data = payload.src.data
  try
    tgtComponent = componentMap[tgtNode]
    tgtPort = componentLib.inputPort(tgtComponent, payload.tgt.port).id
  catch err
    throw new Error "Could not attach IIP: '#{data} -> #{payload.tgt.port} #{tgtNode} : #{err}"
  cmdBuf = dataLiteralToCommand(data, nodeMap[tgtNode].id, tgtPort)
  index += writeCmd buffer, index, 0, cmdBuf
  return index

commands.graph.clear = (payload, buffer, index) ->
  # Clear existing graph
  index += writeCmd(buffer, index, 0, cmdFormat.commands.ClearNodes.id)
  return index

commands.network.start = (payload, buffer, index) ->
  index += writeCmd(buffer, index, 0, cmdFormat.commands.StartNetwork.id)
  return index

commands.network.stop = (payload, buffer, index) ->
  index += writeCmd(buffer, index, 0, cmdFormat.commands.StopNetwork.id)
  return index

commands.network.getstatus = (payload, buffer, index) ->
  index += writeCmd(buffer, index, 0, cmdFormat.commands.GetNetworkStatus.id)
  return index

# The following are MicroFlo specific, not part of FBP runtime protocol
commands.microflo.configuredebug = (payload, buffer, index) ->
  debugLevel = payload.level
  index += writeCmd(buffer, index, 0, cmdFormat.commands.ConfigureDebug.id, cmdFormat.debugLevels[debugLevel].id)
  return index

commands.microflo.opencommunication = (payload, buffer, index) ->
  index += writeString(buffer, index, cmdFormat.magicString)
  buffer[index++] = 0 # space for requestId
  return index

commands.microflo.closecommunication = (payload, buffer, index) ->
  index += writeCmd(buffer, index, 0, cmdFormat.commands.End.id)
  return index

commands.microflo.ping = (payload, buffer, index) ->
  index += writeCmd(buffer, index, 0, cmdFormat.commands.Ping.id)
  return index

# Note: inverse of fromCommand
toCommandStreamBuffer = (message, componentLib, nodeMap, componentMap, buffer, index) ->

  handlers = commands[message.protocol]
  if not handlers?    
    throw new Error "Unknown FBP runtime sub-protocol #{message.protocol}"

  handler = handlers[message.command] 
  if not handler?
    throw new Error "Unknown FBP runtime command #{message.command} for protocol #{message.protocol}"

  requestId = message.requestId
  payload = Object.assign({ request: requestId }, message.payload)
  index = handler payload, buffer, index, componentLib, nodeMap, componentMap

  return index

responses = {}
# Must be named the same as defined in the commands
responses.NetworkStopped = (componentLib, graph) ->
  m =
      protocol: "network"
      command: "stopped"
      payload:
          graph: graph.name
          running: false
          started: false
  return m
responses.NetworkStarted = (componentLib, graph) ->
  m = 
    protocol: "network"
    command: "started"
    payload:
      graph: graph.name
      running: true
      started: true
  return m
responses.NodesCleared = (componentLib, graph) ->
  m =
    protocol: "graph"
    command: "clear"
    payload:
      id: graph.name
  return m
responses.NetworkStatus = (componentLib, graph, cmdData) ->
  running = cmdData.readUInt8(1) == 1
  m =
    protocol: 'network'
    command: 'status'
    payload:
      started: true
      running: running
  return m

responses.NodeAdded = (componentLib, graph, cmdData) ->
  component = componentLib.getComponentById(cmdData.readUInt8(1)).name
  nodeName = nodeNameById(graph.nodeMap, cmdData.readUInt8(2))
  m =
    protocol: 'graph'
    command: 'addnode'
    payload:
      id: nodeName
      component: component
      graph: graph.name
  return m
responses.NodeRemoved = (componentLib, graph, cmdData) ->
  nodeName = nodeNameById(graph.nodeMap, cmdData.readUInt8(1))
  m =
    protocol: 'graph'
    command: 'removenode'
    payload:
      id: nodeName
      graph: graph.name
  return m

responses.NodesConnected = (componentLib, graph, cmdData) ->
  srcNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(1))
  srcPort = componentLib.outputPortById(nodeLookup(graph, srcNode).component, cmdData.readUInt8(2)).name
  targetNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(3))
  targetPort = componentLib.inputPortById(nodeLookup(graph, targetNode).component, cmdData.readUInt8(4)).name
  m =
    protocol: 'graph'
    command: 'addedge'
    payload:
      graph: graph.name
      src:
        node: srcNode
        port: srcPort
      tgt:
        node: targetNode
        port: targetPort
  return m

responses.NodesDisconnected = (componentLib, graph, cmdData) ->
  srcNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(1))
  srcPort = componentLib.outputPortById(nodeLookup(graph, srcNode).component, cmdData.readUInt8(2)).name
  targetNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(3))
  targetPort = componentLib.inputPortById(nodeLookup(graph, targetNode).component, cmdData.readUInt8(4)).name
  m =
    protocol: 'graph'
    command: 'removeedge'
    payload:
      graph: graph.name
      src:
        node: srcNode
        port: srcPort
      tgt:
        node: targetNode
        port: targetPort
  return m

responses.PacketSent = (componentLib, graph, cmdData) ->
  srcNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(1))
  srcPort = componentLib.outputPortById(nodeLookup(graph, srcNode).component, cmdData.readUInt8(2)).name
  hasTarget = cmdData.readUInt8(3) == 1

  # find target (if any) using the graph connection info
  tgt = null
  for edge in graph.connections
    if edge.src.node == srcNode and edge.src.port == srcPort
      tgt = edge.tgt 
  if hasTarget and not tgt
    throw new Error("Failed to find target connection for Packet")

  dataOffset = 4
  { data, type } = deserializeData cmdData, dataOffset

  # Should be mapped to `network:send` on FBP runtime protocol 
  m =
    protocol: "microflo"
    command: "packetsent"
    payload:
      src:
        node: srcNode
        port: srcPort
      tgt: tgt
      data: data
      type: type
  return m

responses.DebugChanged = (componentLib, graph, cmdData) ->
  level = nodeNameById(cmdFormat.debugLevels, cmdData.readUInt8(1))
  m =
    protocol: 'microflo'
    command: 'debugchanged'
    payload:
      level: level
  return m

responses.DebugMessage = (componentLib, graph, cmdData) ->
  level = nodeNameById(cmdFormat.debugLevels, cmdData.readUInt8(1))
  point = nodeNameById(cmdFormat.debugPoints, cmdData.readUInt8(2))
  m =
    protocol: 'microflo'
    command: 'debugmessage'
    payload:
      level: level
      point: point
  return m

responses.PortSubscriptionChanged = (componentLib, graph, cmdData) ->
  node = nodeNameById(graph.nodeMap, cmdData.readUInt8(1))
  port = componentLib.outputPortById(graph.processes[node].component, cmdData.readUInt8(2)).name
  enable = if cmdData.readUInt8(3) then 'true' else 'false'
  # should be mapped to changes in `network:edges` in FBP network protocol
  m =
    protocol: 'microflo'
    command: 'subscribeedge'
    payload:
      node: node
      port: port
      enabled: enable
  return m

responses.SubgraphPortConnected = (componentLib, graph, cmdData) ->
  direction = if cmdData.readUInt8(1) then 'output' else 'input'
  portById = if direction == 'output' then componentLib.outputPortById else componentLib.inputPortById
  subgraphNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(2))
  subgraphPort = portById(nodeLookup(graph, subgraphNode).component, cmdData.readUInt8(3)).name
  childNode = nodeNameById(graph.nodeMap, cmdData.readUInt8(4))
  childPort = portById(nodeLookup(graph, childNode).component, cmdData.readUInt8(5)).name
  # should be mapped to `graph:addedge` in FBP network protocol  
  m =
    protocol: 'microflo'
    command: 'subgraphportconnected'
    payload:
      parent:
        node: subgraphNode
        port: subgraphPort
      child:
        node: childNode
        port: childPort
      enabled: enable 
  return m

responses.CommunicationOpen = () ->
  m =
    protocol: 'microflo'
    command: 'communicationopen'
    payload: null
  return m
responses.Pong = () ->
  m =
    protocol: 'microflo'
    command: 'pong'
    payload: null
  return m
responses.TransmissionEnded = () ->
  m =
    protocol: 'microflo'
    command: 'transmissionended'
    payload: null
  return m
responses.IoValueChanged = () ->
  m =
    protocol: 'microflo'
    command: 'iovaluechanged'
    payload: null
  return m
responses.SetIoValueCompleted = () ->
  m =
    protocol: 'microflo'
    command: 'setiovaluecompleted'
    payload: null
  return m
responses.SendPacketDone = (componentLib, graph) ->
  m =
    protocol: 'runtime'
    command: 'packetsent'
    payload:
      port: 'sssss' # FIXME
      event: 'data'
      type: 'any'
      graph: graph.name
      payload: {} # FIXME
  return m
responses.Error = (componentLib, graph, cmdData) ->
  errorCode = cmdData.readUInt8(1)
  m =
    protocol: 'microflo'
    command: 'error'
    payload:
      error: errorCode
      message: 'error' #FIXME: lookup error message

  return m

buildResponseMapping = () ->
  mapping = {}
  isResponse = (cmd) ->
    return cmd.type == 'response' or cmd.id >= 100 and cmd.id < 255

  for name, f of responses
    c = cmdFormat.commands[name]
    console.log 'Warning: Response handler defined for unknown command:', name if not c
    console.log 'Warning: Response handler defined for non-response:', name if c and not isResponse c

  for name, data of cmdFormat.commands
    func = responses[name]
    continue if not isResponse data
    console.log "Warning: Response command not implemented:", name if not func
    mapping[data.id] = func

  return mapping

responseFromCommandId = buildResponseMapping()

# Return a list of FBP protocol messages
fromCommand = (componentLib, graph, command) ->

  if not componentLib
    throw new Error('Missing component library')
  requestId = command.readUInt8 0
  cmdType = command.readUInt8(1)
  cmdData = command.slice(1) # skip requestId
  responseParser = responseFromCommandId[cmdType]
  if typeof responseParser != 'function'
    throw new Error("Unknown/unsupported command received #{cmdType}")

  messages = responseParser componentLib, graph, cmdData
  if not messages?
    return []
  if not messages.length
    return [messages]
  return messages

# As a list of FBP runtime messages
initialGraphMessages = (graph, graphName, debugLevel, openclose) ->
  messages = []

  # Start comm
  if openclose
    messages.push
      protocol: 'microflo'
      command: 'opencommunication'
      payload: null

  # Stop network execution
  messages.push
    protocol: 'network'
    command: 'stop'
    payload:
      graph: graphName

  # Clear graph
  messages.push
    protocol: 'graph'
    command: 'clear'
    payload:
      id: graphName

  # Config
  messages.push
    protocol: 'microflo'
    command: 'configuredebug'
    payload:
      level: debugLevel

  # Actual graph
  graphMessages = protocol.graphToFbpMessages graph, 'default'
  messages = messages.concat graphMessages

  # Start the network
  messages.push
    protocol: 'network'
    command: 'start'
    payload: null

  # Stop comm
  if openclose
    messages.push
      protocol: 'microflo'
      command: 'closecommunication'
      payload: null

  return messages

# Build component/node mapping
buildMappings = (messages) ->
  nodeMap = {}
  componentMap = {}
  currentNodeId = 1
  for message in messages
    if message.command == 'addnode'
      name = message.payload.id
      # Assign node names in consecutive order. Note: assumes runtime commandstream parsing does the same
      nodeMap[name] =
        id: currentNodeId++
      componentMap[name] = message.payload.component
  r =
    nodes: nodeMap
    components: componentMap
  return r

cmdStreamFromGraph = (componentLib, graph, debugLevel, openclose) ->
  debugLevel = debugLevel or 'Error'
  buffer = Buffer.alloc cmdFormat.commandSize*1024 # FIXME: unhardcode
  index = 0
  graphName = 'default'
  requestId = 1

  messages = initialGraphMessages graph, graphName, debugLevel, openclose
  mapping = buildMappings messages
  for message in messages
    nextIndex = toCommandStreamBuffer message, componentLib, mapping.nodes, mapping.components, buffer, index
    command = buffer.slice(index, nextIndex)
    if message.command == 'opencommunication'
        command.writeUInt8 requestId++, cmdFormat.commandSize-1
    else
        command.writeUInt8 requestId++, 0
    index = nextIndex

  if index % cmdFormat.commandSize != 0
    throw new Error("Command stream length #{index} is not a multiple of command size")

  graph.nodeMap = mapping.nodes # HACK
  buffer = buffer.slice(0, index)
  return buffer

nodeNameById = (nodeMap, wantedId) ->
  for name of nodeMap
    `name = name`
    id = if nodeMap[name].id != undefined then nodeMap[name].id else nodeMap[name]
    if id == wantedId
      return name
  return

nodeLookup = (graph, nodeName) ->
  parent = graph.nodeMap[nodeName].parent
  r = if parent != undefined then graph.processes[nodeNameById(graph.nodeMap, parent)].graph.processes else graph.processes
  r[nodeName]

module.exports =
  cmdStreamFromGraph: cmdStreamFromGraph
  dataLiteralToCommand: dataLiteralToCommand
  dataToCommand: dataToCommand
  dataLiteralToCommandDescriptions: dataLiteralToCommandDescriptions
  writeCmd: writeCmd
  writeString: writeString
  cmdFormat: cmdFormat
  format: cmdFormat
  Buffer: Buffer
  buildMappings: buildMappings
  initialGraphMessages: initialGraphMessages
  toCommandStreamBuffer: toCommandStreamBuffer
  fromCommand: fromCommand
  commands: commands
