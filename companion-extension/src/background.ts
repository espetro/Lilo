// Service worker entry: wires the native-messaging port to the tool implementations.
import { connect } from "./nativePort.ts";

connect();
