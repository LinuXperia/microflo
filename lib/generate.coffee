# MicroFlo - Flow-Based Programming for microcontrollers
# * Copyright (c) 2013 Jon Nordby <jononor@gmail.com>
# * MicroFlo may be freely distributed under the MIT license
#
util = require("./util")
cmdFormat = require("./commandformat")
commandstream = require("./commandstream")
definition = require("./definition")

fs = require("fs")
path = require("path")
declarec = require("declarec")

cmdStreamToCDefinition = (cmdStream, target) ->
  out = ""
  if target is "arduino:avr" or target is "avr"
    out += "#include <avr/pgmspace.h>\n"
    out += '#define MICROFLO_GRAPH_PROGMEM'
    out += cmdStreamToC(cmdStream, "PROGMEM")
  else
    out += cmdStreamToC(cmdStream)
  out

cmdStreamValuesToC = (cmdStream) ->
  values = []
  i = 0

  while i < cmdStream.length
    values[i] = "0x" + cmdStream.readUInt8(i).toString(16)
    i++
  values = values.join(",")
  prettyValues = ""
  commas = 0
  i = 0

  while i < values.length
    commas += 1  if values[i] is ","
    prettyValues = prettyValues.concat(values[i])
    if commas and (commas % cmdFormat.commandSize) is 0
      prettyValues = prettyValues.concat("\n")
      commas = 0
    i++
  return prettyValues

cmdStreamToC = (cmdStream, annotation) ->
  annotation = ""  unless annotation
  variableName = "graph"

  prettyValues = cmdStreamValuesToC cmdStream  
  cCode = "const unsigned char " + variableName + "[] " + annotation + " = {\n" + prettyValues + "\n};"
  cCode

generateConstInt = (prefix, iconsts) ->
  return ""  if Object.keys(iconsts).length is 0
  indent = "\n const MicroFlo::ComponentId "
  out = "#ifndef COMPONENTLIB_IDS_H\n#define COMPONENTLIB_IDS_H\n\n"
  out += "// Component Id constants\n"
  out += "namespace {"
  a = []
  for e of iconsts
    continue  unless iconsts.hasOwnProperty(e)
    a.push (indent + prefix + e + ((if (iconsts[e].id isnt `undefined`) then " = " + iconsts[e].id else "")))
  out += a.join(";")
  out += ";\n};\n\n"
  out += "#endif // COMPONENTLIB_IDS_H\n"
  out

generateEnum = (name, prefix, enums) ->
  return ""  if Object.keys(enums).length is 0
  indent = "\n    "
  out = "enum " + name + " {"
  a = []
  for e of enums
    continue  unless enums.hasOwnProperty(e)
    a.push (indent + prefix + e + ((if (enums[e].id isnt `undefined`) then " = " + enums[e].id else "")))
  out += a.join(",")
  out += "\n};\n"
  out

componentPortDefinition = (componentLib, name) ->
    out = ""
    out += "\n" + "namespace " + name + "Ports {\n"
    out += "struct InPorts {\n"
    out += generateEnum("Ports", "", componentLib.inputPortsFor(name))
    out += "};\n"
    out += "struct OutPorts {\n"
    out += generateEnum("Ports", "", componentLib.outputPortsFor(name))
    out += "};"
    out += "\n}\n"
    return out

generateComponentPortDefinitions = (componentLib) ->
  out = "#ifndef COMPONENTLIB_PORTS_H\n#define COMPONENTLIB_PORTS_H\n\n"
  for name of componentLib.getComponents()
    out += componentPortDefinition componentLib, name
  out += "\n#endif // COMPONENTLIB_PORTS_H\n"
  out

generateComponentFactory = (componentLib, methodName) ->
  out = "// Component factory functionality\nComponent *" + methodName + "(MicroFlo::ComponentId id) {"
  indent = "\n    "
  out += indent + "Component *c;"
  out += indent + "switch (id) {"
  for name of componentLib.getComponents()
    comp = componentLib.getComponent(name)
    instantiator = "new " + "::" + name
    if typeof comp.type isnt "undefined" and comp.type is "pure2"
      t0 = componentLib.inputPortById(name, 0).ctype
      t1 = componentLib.inputPortById(name, 0).ctype
      instantiator = "new PureFunctionComponent2<" + name + "," + t0 + "," + t1 + ">"
    out += indent + "case Id" + name + ": c = " + instantiator + "; c->setComponentId(id); return c;"
  out += indent + "default: return NULL;"
  out += indent + "}"
  out += "}"
  out

endsWith = (str, suffix) ->
  str.indexOf(suffix) is str.length - suffix.length

generateComponentIncludes = (componentLib) ->
  out = ""
  for name of componentLib.getComponents()
    comp = componentLib.getComponent(name)

    # TODO: build up list of files, eliminate duplicates
    out += "#include \"" + comp.filename + "\"\n"  if comp.filename and not endsWith(comp.filename, ".cpp")
  out

generateComponentMap = (componentLib) ->
  # TODO: store more efficiently, so can be embedded in uC?
  # TODO: store hash/versioning, so can be found by embedding just ID in uC?
  out = JSON.stringify componentLib.definition
  return out

macroSafeName = (str) ->
  str.split(".").join("_").split("-").join "_"

guardHead = (filename) ->
  guardname = "_" + macroSafeName(filename)
  "#ifndef " + guardname + "\n" + "#define " + guardname + "\n"

guardTail = (filename) ->
  guardname = "_" + macroSafeName(filename)
  "#endif //" + guardname + "\n"

extractId = (map, key) ->
  map[key].id

componentLibDefinitions = (componentLib, factoryMethodName) ->
  ids = generateConstInt("Id", componentLib.getComponents(true, true))
  ports = generateComponentPortDefinitions(componentLib)

  includes = generateComponentIncludes(componentLib)
  factory = generateComponentFactory(componentLib, factoryMethodName)
  sourceOutput = includes + "\n\n" + factory
  all = ids + ports + sourceOutput
  map = generateComponentMap componentLib

  r =
    ids: ids
    ports: ports
    includes: includes
    factory: factory
    source: sourceOutput
    map: map
    all: all
  return r

getDefinitions = (baseDir) ->
  contents = "// !! WARNING: This file is generated from commandformat.json !!" +
        "\n" + generateEnum("GraphCmd", "GraphCmd", cmdFormat.commands) +
        "\n" + declarec.generateStringMap('GraphCmd_names', cmdFormat.commands, extractId) +
        "\n" + generateEnum("Msg", "Msg", cmdFormat.packetTypes) +
        "\n" + declarec.generateStringMap('Msg_names', cmdFormat.packetTypes, extractId) +
        "\n" + generateEnum("DebugLevel", "DebugLevel", cmdFormat.debugLevels) +
        "\n" + declarec.generateStringMap('DebugLevel_names', cmdFormat.debugLevels, extractId) +
        "\n" + generateEnum("DebugId", "Debug", cmdFormat.debugPoints) +
        "\n" + declarec.generateStringMap('DebugId_names', cmdFormat.debugPoints, extractId) +
        "\n" + generateEnum("Error", "Error", cmdFormat.errors) +
        "\n" + declarec.generateStringMap('Error_names', cmdFormat.errors, extractId) +
        "\n" + generateEnum("IoType", "IoType", cmdFormat.ioTypes) +
        "\n" + declarec.generateStringMap('IoType_names', cmdFormat.ioTypes, extractId)
  return contents

declareSize = (name, value) ->
    return "const size_t #{name} = #{value};"

declareArray = (name, type, array) ->
    str = "const #{type} #{name}[] = {\n"
    for v in array
        str += "    #{v}\n"
    str += "};\n"
    return str

generateExported = (prefix, def, componentLib, type) ->
    getPorts = if type == 'inport' then 'inputPortsFor' else 'outputPortsFor'

    portNo = 0
    portIds = []
    nodeIds = []
    names = {}
    for exported, internal of def[type+'s']
        exportId = portNo++
        names[exported] = exportId
        nodeIds.push def.nodeMap[internal.process].id

        # resolve port id
        c = def.processes[internal.process].component
        ports = componentLib[getPorts] c
        p = ports[internal.port]
        portIds.push p.id

    cname = prefix+"#{type}s_"
    str = declareSize(cname+"length", portNo) +
        '\n' + declarec.generateStringMap(cname+"name", names) +
        '\n' + declareArray(cname+'node', 'MicroFlo::NodeId', nodeIds) +
        '\n' + declareArray(cname+'port', 'MicroFlo::PortId', portIds)

exportedPorts = (prefix, def, componentLib) ->

    str = '// Top-level exported ports\n' +
        generateExported(prefix, def, componentLib, 'inport') + '\n' +
        generateExported(prefix, def, componentLib, 'outport')

    return str

exportGraphName = (variable, graph) ->
  graphName = graph.properties.name or "unknown"
  return "static const char *const #{variable} = \"#{graphName}\";"


include = (file) ->
  return "#include \"#{file}\""
define = (symbol, val) ->
  return "#define #{symbol} #{val}"

extension = (target) ->
  ext = '.cpp'
  ext = '.ino' if target == 'arduino'
  return ext

generateGraphMaps = (componentLib, def) ->
  maps = declarec.generateStringMap("graph_nodeMap", def.nodeMap, extractId) +
      '\n' + exportedPorts('graph_', def, componentLib) +
      '\n' + exportGraphName('graph_name', def) +
      '\n'
  return maps


generateOutput = (componentLib, graph, outputFile, target, mainFile, enableMaps) ->
  outputBase = undefined
  outputDir = undefined
  outputBase = outputFile.replace(path.extname(outputFile), "")
  outputDir = path.dirname outputBase

  enableMaps = false if not enableMaps?

  microfloDir = path.join __dirname, '..', 'microflo'

  if not mainFile
    # default to file included with MicroFlo
    mainFile = path.join microfloDir, "#{target.replace('-', '_')}_main.hpp"

  componentGen = componentLibDefinitions componentLib, 'createComponent'
  files = {}
  files[outputDir + "/componentlib-ids.h"] = componentGen.ids
  files[outputDir + "/componentlib-ports.h"] = componentGen.ports
  files[outputDir + "/componentlib-map.json"] = componentGen.map
  files[outputDir + "/componentlib.hpp"] = componentGen.all

  graphData = commandstream.cmdStreamFromGraph(componentLib, graph, null, true)
  graphMaps = generateGraphMaps componentLib, graph

  files[outputBase + ".json"] = JSON.stringify graph
  files[outputBase + ".fbcs"] = graphData
  files[outputBase + ".h"] = cmdStreamToCDefinition(graphData, target)
  files[outputBase + "_maps.h"] = graphMaps

  includes = "// !!! generated by: microflo generate\n"
  includes += cmdStreamToCDefinition(graphData, target) + '\n'
  includes += "#define MICROFLO_EMBED_GRAPH 1" + '\n'

  includes += include(path.join(microfloDir, 'microflo.h')) + '\n'

  if enableMaps
    includes += "// Graph metadata\n" 
    includes += graphMaps + "\n"

  includes += include(mainFile) + '\n'
  includes += include('./componentlib.hpp') + '\n'

  files[outputFile] = includes

  return { directory: outputDir, files: files }

module.exports =
  getDefinitions: getDefinitions
  cmdStreamToCDefinition: cmdStreamToCDefinition
  generateEnum: generateEnum
  generateOutput: generateOutput

