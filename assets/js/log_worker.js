// Web Worker entry for the build-log viewer: owns the log bytes off the main thread.
import {createLogEngine} from "./log_core.mjs"

const engine = createLogEngine((message) => {
  if (message.matches instanceof Uint32Array) postMessage(message, [message.matches.buffer])
  else postMessage(message)
})
onmessage = ({data}) => engine(data)
