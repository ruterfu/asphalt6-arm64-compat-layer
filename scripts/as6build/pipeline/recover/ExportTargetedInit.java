// Temporary local disassembly of exact Capstone-discovered addresses only.
// Existing project is opened readOnly/noanalysis; transaction always rolls back.
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.program.database.ProgramDB;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import com.google.gson.*;
import java.io.*;
import java.math.BigInteger;
import java.nio.file.*;
import java.util.*;

public class ExportTargetedInit extends GhidraScript {
    private static String hex(long value) {return String.format("0x%x",value);}
    private JsonObject node(Varnode value) {
        JsonObject out=new JsonObject();out.addProperty("space",value.getAddress().getAddressSpace().getName());
        out.addProperty("offset",hex(value.getOffset()));out.addProperty("size",value.getSize());
        if(value.isRegister()) {Register reg=currentProgram.getLanguage().getRegister(value.getAddress(),value.getSize());if(reg!=null)out.addProperty("register_name",reg.getName());}
        return out;
    }
    private JsonObject instruction(Instruction ins,byte[] original) throws Exception {
        long pc=ins.getAddress().getOffset();byte[] raw=ins.getBytes();StringBuilder bytes=new StringBuilder();
        if(raw.length!=4)throw new IllegalStateException("Unexpected recovered instruction width");
        for(int i=0;i<raw.length;i++) {if(raw[i]!=original[(int)pc-0x1000+i])throw new IllegalStateException("Original byte mismatch at "+hex(pc));bytes.append(String.format("%02x",raw[i]&255));}
        JsonObject out=new JsonObject();out.addProperty("address",hex(pc));out.addProperty("size",raw.length);
        out.addProperty("bytes",bytes.toString());out.addProperty("source_file_offset",hex(pc-0x1000));out.addProperty("original_bytes_match",true);
        out.addProperty("asm",ins.toString());out.addProperty("mnemonic",ins.getMnemonicString());out.addProperty("flow_type",ins.getFlowType().toString());
        if(ins.getFallThrough()==null)out.add("fallthrough",JsonNull.INSTANCE);else out.addProperty("fallthrough",hex(ins.getFallThrough().getOffset()));
        JsonArray flows=new JsonArray();for(Address target:ins.getFlows())flows.add(hex(target.getOffset()));out.add("flows",flows);
        JsonObject context=new JsonObject();for(Register reg:currentProgram.getLanguage().getRegisters())if(reg.isProcessorContext()) {
            BigInteger value=ins.getValue(reg,false);if(value!=null)context.addProperty(reg.getName(),"0x"+value.toString(16));
        }
        if(!context.has("TMode")||!context.get("TMode").getAsString().equals("0x0"))throw new IllegalStateException("Recovered instruction is not ARM");
        out.add("context",context);JsonArray pcode=new JsonArray();PcodeOp[] ops=ins.getPcode();
        for(int index=0;index<ops.length;index++) {
            PcodeOp op=ops[index];JsonObject row=new JsonObject();row.addProperty("index",index);row.addProperty("op",op.getOpcode());row.addProperty("name",op.getMnemonic());
            row.add("output",op.getOutput()==null?JsonNull.INSTANCE:node(op.getOutput()));JsonArray inputs=new JsonArray();for(Varnode input:op.getInputs())inputs.add(node(input));row.add("inputs",inputs);
            if(op.getOpcode()==PcodeOp.CALLOTHER) {int id=(int)op.getInput(0).getOffset();row.addProperty("userop_id",id);row.addProperty("userop_name",currentProgram.getLanguage().getUserDefinedOpName(id));}
            pcode.add(row);
        }
        out.add("pcode",pcode);return out;
    }
    @Override public void run() throws Exception {
        String[] args=getScriptArgs();byte[] original=Files.readAllBytes(Paths.get(args[1]));
        List<Address> addresses=new ArrayList<>();AddressSet starts=new AddressSet(),restricted=new AddressSet();
        for(String line:Files.readAllLines(Paths.get(args[2]))) {
            Address pc=currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(Long.decode(line));
            if(pc.getOffset()<0x2a269cL||pc.getOffset()>=0x2a40ecL||currentProgram.getListing().getInstructionAt(pc)!=null)throw new IllegalStateException("Address not in original unknown initializer slice");
            addresses.add(pc);starts.add(pc);restricted.add(pc,pc.add(3));
        }
        // Headless scripts may already own an outer source transaction, so an
        // inner abort is not immediately observable. Use a tiny in-memory
        // fragment ProgramDB instead; never mutate the existing project.
        Program source=currentProgram;
        CompilerSpec compiler=source.getLanguage().getCompilerSpecByID(source.getCompilerSpec().getCompilerSpecID());
        ProgramDB scratch=new ProgramDB("targeted_init_original_fragment",source.getLanguage(),compiler,this);
        currentProgram=scratch;
        int transaction=scratch.startTransaction("Temporary exact initializer recovery; always rollback");
        JsonArray recovered=new JsonArray();
        try {
            Address base=scratch.getAddressFactory().getDefaultAddressSpace().getAddress(0x2a269cL);
            scratch.getMemory().createInitializedBlock("original_init_fragment",base,6736,(byte)0,monitor,false);
            scratch.getMemory().setBytes(base,Arrays.copyOfRange(original,0x2a169c,0x2a30ec));
            RegisterValue arm=new RegisterValue(currentProgram.getProgramContext().getRegister("TMode"),BigInteger.ZERO);
            DisassembleCommand command=new DisassembleCommand(starts,restricted,false);command.setInitialContext(arm);command.enableCodeAnalysis(false);
            if(!command.applyTo(currentProgram,monitor))throw new IllegalStateException("Targeted disassembly: "+command.getStatusMsg());
            for(Address pc:addresses) {
                monitor.checkCancelled();Instruction ins=currentProgram.getListing().getInstructionAt(pc);
                if(ins==null)throw new IllegalStateException("Missing exact recovered instruction: "+pc);
                recovered.add(instruction(ins,original));
            }
        } finally {scratch.endTransaction(transaction,false);}
        try {
            for(Address pc:addresses)if(scratch.getListing().getInstructionAt(pc)!=null)throw new IllegalStateException("Scratch rollback failed");
            if(scratch.getMemory().getBlocks().length!=0)throw new IllegalStateException("Scratch memory rollback failed");
        } finally {currentProgram=source;scratch.release(this);}
        JsonObject document=JsonParser.parseString(Files.readString(Paths.get(args[3]))).getAsJsonObject();
        document.addProperty("instruction_count",recovered.size());document.addProperty("every_instruction_original_bytes_match",true);
        document.addProperty("pcode_source","Instruction.getPcode()");
        document.addProperty("recovery_provenance","temporary exact scratch disassembly, transaction rolled back, no reanalysis");
        document.addProperty("targeted_init_source_slot","0x701c68");document.addProperty("original_unknown_bytes_admitted_as_code",recovered.size()*4);
        document.addProperty("project_changes_rolled_back",true);document.addProperty("automatic_analysis_enabled",false);
        document.addProperty("source_project_mutated",false);document.addProperty("scratch_original_fragment_bytes",6736);
        document.remove("sampling");document.remove("opcode_names");
        JsonObject function=new JsonObject();function.addProperty("scope","function");function.addProperty("entry","0x2a40e0");function.addProperty("name","recovered_original_init_2a40e0");
        JsonArray ranges=new JsonArray();for(Address pc:addresses) {JsonObject range=new JsonObject();range.addProperty("start",hex(pc.getOffset()));range.addProperty("end_inclusive",hex(pc.getOffset()+3));ranges.add(range);}
        function.add("body_ranges",ranges);function.addProperty("body_address_count",recovered.size()*4);function.add("instructions",recovered);
        JsonArray functions=new JsonArray();functions.add(function);document.add("functions",functions);
        try(Writer writer=new FileWriter(args[0])) {new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(document,writer);}
        println("TARGETED_INIT_RECOVERED instructions="+recovered.size()+" bytes="+(recovered.size()*4)+" rollback=true");
    }
}
