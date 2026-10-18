import { spawn } from "buoy";

class Store {}
const pick = (): typeof Store => Store;
spawn(pick());
