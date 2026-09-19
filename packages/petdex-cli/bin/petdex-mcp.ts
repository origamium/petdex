// Standalone desktop asset: no registry lookup or CLI dependencies at runtime.
import { runMcpServer } from "../src/hooks/mcp-server";

await runMcpServer();
