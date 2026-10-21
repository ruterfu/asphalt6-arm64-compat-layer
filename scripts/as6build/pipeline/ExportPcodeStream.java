// Build-time-only streaming export; no target execution and no decompiler.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.*;
import com.google.gson.*;
import com.google.gson.stream.JsonWriter;
import java.io.*;
import java.nio.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.GZIPOutputStream;

public class ExportPcodeStream extends GhidraScript {
    private static final char[] DIGITS = "0123456789abcdef".toCharArray();
    private MappedByteBuffer original;
    private final List<long[]> segments = new ArrayList<>();
    private final Map<Long, String> exactRegisters = new HashMap<>();
    private final List<Register> contextRegisters = new ArrayList<>();
    private final Map<String, Long> opcodeCounts = new TreeMap<>(), useropCounts = new TreeMap<>();
    private final Map<String, Long> microBranches = new TreeMap<>();
    private final List<String> microBackedgeSamples = new ArrayList<>();
    private long exported, instructionBytes, outsideFunctions, omittedRanges, omittedBytes;
    private final List<long[]> omittedSamples = new ArrayList<>();

    private static class RecordBuffer extends Writer {
        final StringBuilder text = new StringBuilder(16384);
        @Override public void write(char[] value, int offset, int length) { text.append(value, offset, length); }
        @Override public void write(String value) { text.append(value); }
        @Override public void write(String value, int offset, int length) { text.append(value, offset, offset + length); }
        @Override public void write(int value) { text.append((char)value); }
        @Override public void flush() { }
        @Override public void close() { }
        void clear() { text.setLength(0); }
        void send(Writer target) throws IOException { target.write(text.toString()); target.write('\n'); clear(); }
    }
    private static String hex(long value) { return "0x" + Long.toUnsignedString(value, 16); }
    private static String bytesHex(byte[] value) {
        char[] result = new char[value.length * 2];
        for (int i = 0; i < value.length; i++) { result[2*i] = DIGITS[(value[i] >>> 4) & 15]; result[2*i+1] = DIGITS[value[i] & 15]; }
        return new String(result);
    }
    private static String hash(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream stream = Files.newInputStream(path)) {
            byte[] buffer = new byte[262144]; int count;
            while ((count = stream.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return bytesHex(digest.digest());
    }
    private static JsonWriter json(Writer writer) { JsonWriter out = new JsonWriter(writer); out.setSerializeNulls(true); out.setLenient(true); return out; }
    private static BufferedWriter gzip(Path path) throws IOException {
        return new BufferedWriter(new OutputStreamWriter(new GZIPOutputStream(Files.newOutputStream(path), 262144), StandardCharsets.UTF_8), 524288);
    }
    private void parseSegments() {
        original.order(ByteOrder.LITTLE_ENDIAN);
        if (original.getInt(0) != 0xfeedface || original.getInt(4) != 12) throw new IllegalArgumentException("Expected thin original ARM Mach-O");
        int count = original.getInt(16), commandBytes = original.getInt(20), offset = 28;
        for (int i = 0; i < count; i++) {
            int command = original.getInt(offset), size = original.getInt(offset + 4);
            if (size < 8 || offset + (long)size > 28L + commandBytes) throw new IllegalArgumentException("Malformed Mach-O command");
            if (command == 1) {
                if (size < 56) throw new IllegalArgumentException("Truncated segment");
                segments.add(new long[]{Integer.toUnsignedLong(original.getInt(offset + 24)),
                    Integer.toUnsignedLong(original.getInt(offset + 28)), Integer.toUnsignedLong(original.getInt(offset + 32)),
                    Integer.toUnsignedLong(original.getInt(offset + 36))});
            }
            if (command == 0x21 && (size < 20 || original.getInt(offset + 16) != 0)) throw new IllegalArgumentException("Encrypted image");
            offset += size;
        }
        if (offset != 28 + commandBytes) throw new IllegalArgumentException("Mach-O command extent mismatch");
    }
    private long verifyBytes(Instruction instruction, byte[] bytes) {
        long address = instruction.getAddress().getOffset();
        for (long[] segment : segments) {
            long delta = address - segment[0], offset = segment[2] + delta;
            if (delta < 0 || delta + bytes.length > segment[3]) continue;
            if (offset < 0 || offset + bytes.length > original.capacity()) throw new IllegalStateException("Original instruction exceeds file");
            for (int i = 0; i < bytes.length; i++) if (original.get((int)offset + i) != bytes[i])
                throw new IllegalStateException("Original instruction mismatch at " + instruction.getAddress());
            return offset;
        }
        throw new IllegalStateException("Instruction is not original file-backed code: " + instruction.getAddress());
    }
    private void node(JsonWriter out, Varnode value) throws IOException {
        out.beginObject().name("space").value(value.getAddress().getAddressSpace().getName())
            .name("offset").value(hex(value.getOffset())).name("size").value(value.getSize());
        if (value.isRegister()) {
            String name = exactRegisters.get((value.getOffset() << 8) | value.getSize());
            if (name != null) out.name("register_name").value(name);
        }
        out.endObject();
    }
    private void header(JsonWriter out, String imageHash, JsonObject inventory, MemoryBlock text, String omissionsName) throws IOException {
        out.beginObject().name("record_type").value("header").name("schema").value("as6-raw-pcode-stream-v1")
            .name("schema_version").value(1).name("image_sha256").value(imageHash)
            .name("program_name").value(currentProgram.getName()).name("lang").value(currentProgram.getLanguageID().toString())
            .name("compiler").value(currentProgram.getCompilerSpec().getCompilerSpecID().toString())
            .name("byte_order").value(currentProgram.getLanguage().isBigEndian() ? "big" : "little")
            .name("pcode_source").value("Instruction.getPcode()").name("flow_overrides_included").value(false)
            .name("build_time_only").value(true).name("original_image_embedded").value(false)
            .name("expected_instruction_count").value(inventory.get("pcode_instruction_queries").getAsLong())
            .name("text_start").value(hex(text.getStart().getOffset())).name("text_end_exclusive").value(hex(text.getEnd().getOffset()+1))
            .name("omitted_ranges_file").value(omissionsName).name("address_spaces").beginArray();
        for (AddressSpace space : currentProgram.getAddressFactory().getAllAddressSpaces()) {
            out.beginObject().name("name").value(space.getName()).name("id").value(space.getSpaceID()).name("type").value(space.getType())
                .name("size_bits").value(space.getSize()).name("addressable_unit_size").value(space.getAddressableUnitSize())
                .name("constant").value(space.isConstantSpace()).name("unique").value(space.isUniqueSpace())
                .name("register").value(space.isRegisterSpace()).name("memory").value(space.isMemorySpace()).endObject();
        }
        out.endArray().name("registers").beginArray();
        List<Register> registers = new ArrayList<>(currentProgram.getLanguage().getRegisters());
        registers.sort(Comparator.comparing((Register r) -> r.getAddress().getAddressSpace().getName())
            .thenComparingLong(r -> r.getAddress().getOffset()).thenComparing(Register::getName));
        for (Register register : registers) {
            if (register.isProcessorContext()) contextRegisters.add(register);
            if (register.getAddress().getAddressSpace().isRegisterSpace() && register.getBitLength() == register.getMinimumByteSize()*8) {
                Register canonical = currentProgram.getLanguage().getRegister(register.getAddress(), register.getMinimumByteSize());
                if (canonical != null && canonical.getBitLength() == register.getMinimumByteSize()*8)
                    exactRegisters.put((register.getAddress().getOffset() << 8) | register.getMinimumByteSize(), canonical.getName());
            }
            out.beginObject().name("name").value(register.getName()).name("space").value(register.getAddress().getAddressSpace().getName())
                .name("offset").value(hex(register.getAddress().getOffset())).name("size").value(register.getMinimumByteSize())
                .name("bit_length").value(register.getBitLength()).name("least_significant_bit").value(register.getLeastSignificantBit())
                .name("least_significant_bit_in_base").value(register.getLeastSignificantBitInBaseRegister())
                .name("base_register").value(register.getBaseRegister().getName()).name("processor_context").value(register.isProcessorContext())
                .name("children").beginArray();
            for (Register child : register.getChildRegisters()) out.value(child.getName());
            out.endArray().endObject();
        }
        out.endArray().name("userops").beginArray();
        for (int id = 0; id < currentProgram.getLanguage().getNumberOfUserDefinedOpNames(); id++)
            out.beginObject().name("id").value(id).name("name").value(currentProgram.getLanguage().getUserDefinedOpName(id)).endObject();
        out.endArray().name("limitations").value("Frozen Listing only; ARM:LE:32:v8/default, no reanalysis or reachability proof. Non-instruction ranges are not decoded or embedded. Original instructions/p-code are build-time evidence and must not ship in the final app.").endObject();
    }
    private void instruction(JsonWriter out, Instruction instruction, byte[] bytes, long fileOffset, PcodeOp[] operations, boolean outside) throws IOException {
        out.beginObject().name("record_type").value("instruction").name("scope").value("instruction")
            .name("address").value(hex(instruction.getAddress().getOffset())).name("size").value(bytes.length)
            .name("bytes").value(bytesHex(bytes)).name("source_file_offset").value(hex(fileOffset)).name("original_bytes_match").value(true)
            .name("outside_function_body_union").value(outside).name("asm").value(instruction.toString())
            .name("mnemonic").value(instruction.getMnemonicString()).name("flow_type").value(instruction.getFlowType().toString())
            .name("fallthrough").value(instruction.getFallThrough() == null ? null : hex(instruction.getFallThrough().getOffset()))
            .name("flows").beginArray();
        for (Address flow : instruction.getFlows()) out.value(hex(flow.getOffset()));
        out.endArray().name("context").beginObject();
        for (Register register : contextRegisters) {
            java.math.BigInteger value = instruction.getValue(register, false);
            if (value != null) out.name(register.getName()).value("0x" + value.toString(16));
        }
        out.endObject().name("pcode").beginArray();
        for (int index = 0; index < operations.length; index++) {
            PcodeOp operation = operations[index]; String mnemonic = operation.getMnemonic();
            opcodeCounts.put(mnemonic, opcodeCounts.getOrDefault(mnemonic, 0L) + 1);
            if ((operation.getOpcode()==PcodeOp.BRANCH || operation.getOpcode()==PcodeOp.CBRANCH) && operation.getInput(0).isConstant()) {
                Varnode destination=operation.getInput(0); int bits=destination.getSize()*8; long delta=destination.getOffset();
                if(bits<64) { delta&=(1L<<bits)-1; if((delta&(1L<<(bits-1)))!=0) delta-=1L<<bits; }
                long target=index+delta; String kind=delta<0 ? "backward" : delta==0 ? "self" : "forward";
                microBranches.put(kind,microBranches.getOrDefault(kind,0L)+1);
                if(target<0 || target>operations.length) microBranches.put("out_of_range",microBranches.getOrDefault("out_of_range",0L)+1);
                if(delta<=0 && microBackedgeSamples.size()<16) microBackedgeSamples.add(hex(instruction.getAddress().getOffset())+":"+index+"->"+target);
            }
            out.beginObject().name("index").value(index).name("op").value(operation.getOpcode()).name("name").value(mnemonic).name("output");
            if (operation.getOutput() == null) out.nullValue(); else node(out, operation.getOutput());
            out.name("inputs").beginArray(); for (Varnode input : operation.getInputs()) node(out, input); out.endArray();
            if (operation.getOpcode() == PcodeOp.CALLOTHER && operation.getNumInputs() > 0) {
                int id = (int)operation.getInput(0).getOffset(); String name = currentProgram.getLanguage().getUserDefinedOpName(id);
                out.name("userop_id").value(id).name("userop_name").value(name);
                String key = id + ":" + (name == null ? "unnamed" : name);
                useropCounts.put(key, useropCounts.getOrDefault(key, 0L) + 1);
            }
            out.endObject();
        }
        out.endArray().endObject();
    }
    private void omission(Writer target, long start, long end) throws IOException {
        if (end < start) return;
        target.write("{\"record_type\":\"non_instruction_range\",\"start\":\""+hex(start)+"\",\"end_inclusive\":\""+hex(end)+"\",\"size\":"+(end-start+1)+",\"classification\":\"not_a_defined_listing_instruction\"}\n");
        omittedRanges++; omittedBytes += end-start+1;
        if (omittedSamples.size() < 16) omittedSamples.add(new long[]{start,end});
    }
    private static void histogram(JsonWriter out, String key, Map<String,Long> counts) throws IOException {
        out.name(key).beginObject(); for (Map.Entry<String,Long> item : counts.entrySet()) out.name(item.getKey()).value(item.getValue()); out.endObject();
    }
    private void summary(JsonWriter out, boolean complete, String beforeHash, String afterHash, long expected,
                         String omissionsName, Instruction failed, Throwable failure) throws IOException {
        out.beginObject().name("record_type").value("summary").name("complete").value(complete).name("instruction_count").value(exported)
            .name("instruction_bytes").value(instructionBytes).name("expected_instruction_count").value(expected)
            .name("outside_function_body_union_count").value(outsideFunctions).name("within_function_body_union_count").value(exported-outsideFunctions)
            .name("source_sha256_before").value(beforeHash).name("source_sha256_after").value(afterHash)
            .name("source_hash_unchanged").value(beforeHash.equals(afterHash)).name("every_instruction_original_bytes_match").value(true)
            .name("omitted_ranges_file").value(omissionsName).name("omitted_range_count").value(omittedRanges).name("omitted_byte_count").value(omittedBytes)
            .name("omitted_range_samples").beginArray();
        for (long[] range : omittedSamples) out.beginObject().name("start").value(hex(range[0])).name("end_inclusive").value(hex(range[1])).endObject();
        out.endArray().name("failure_range");
        if (failed == null) out.nullValue(); else out.beginObject().name("start").value(hex(failed.getAddress().getOffset())).name("end_inclusive").value(hex(failed.getMaxAddress().getOffset())).endObject();
        out.name("error_type").value(failure == null ? null : failure.getClass().getName()).name("error_message").value(failure == null ? null : failure.getMessage());
        histogram(out,"opcode_histogram",opcodeCounts); histogram(out,"userop_histogram",useropCounts);
        histogram(out,"micro_const_branch_histogram",microBranches);
        out.name("micro_backedge_samples").beginArray(); for(String sample:microBackedgeSamples) out.value(sample); out.endArray();
        out.name("micro_backedge_definition").value("const-space BRANCH/CBRANCH target index <= current index; signed displacement uses its varnode byte width").endObject();
    }
    @Override public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 4) throw new IllegalArgumentException("Expected original-image stream.gz non-instruction-ranges.gz inventory.json");
        Path source=Path.of(args[0]), destination=Path.of(args[1]), omissionsPath=Path.of(args[2]);
        JsonObject inventory=JsonParser.parseString(Files.readString(Path.of(args[3]))).getAsJsonObject();
        String beforeHash=hash(source);
        if (!beforeHash.equalsIgnoreCase(currentProgram.getExecutableSHA256()) || !beforeHash.equalsIgnoreCase(inventory.get("database_executable_sha256").getAsString())) throw new IllegalStateException("Original image digest mismatch");
        if (!currentProgram.getLanguageID().toString().equals(inventory.get("language").getAsString())) throw new IllegalStateException("Inventory language mismatch");
        long expected=inventory.get("pcode_instruction_queries").getAsLong();
        MemoryBlock text=currentProgram.getMemory().getBlock("__text");
        if (text==null) throw new IllegalStateException("Missing __text");
        AddressSet bounds=new AddressSet(text.getStart(),text.getEnd()), functionBodies=new AddressSet();
        FunctionIterator functions=currentProgram.getFunctionManager().getFunctions(true);
        while(functions.hasNext()) functionBodies.add(functions.next().getBody());
        Instruction current=null; boolean complete=false; Throwable failure=null;
        RecordBuffer buffer=new RecordBuffer(); JsonWriter out=json(buffer);
        try (FileChannel file=FileChannel.open(source,StandardOpenOption.READ);
             BufferedWriter target=gzip(destination); BufferedWriter omitted=gzip(omissionsPath)) {
            original=file.map(FileChannel.MapMode.READ_ONLY,0,file.size()); parseSegments();
            header(out,beforeHash,inventory,text,omissionsPath.getFileName().toString()); buffer.send(target);
            long cursor=text.getStart().getOffset(), previous=-1;
            try {
                InstructionIterator iterator=currentProgram.getListing().getInstructions(bounds,true);
                while(iterator.hasNext()) {
                    monitor.checkCancelled(); current=iterator.next(); long address=current.getAddress().getOffset();
                    if(address<=previous || !bounds.contains(current.getAddress(),current.getMaxAddress())) throw new IllegalStateException("Instruction ordering or extent failure");
                    byte[] bytes=current.getBytes(); if(bytes.length!=current.getLength()) throw new IllegalStateException("Instruction length mismatch");
                    long offset=verifyBytes(current,bytes); PcodeOp[] operations=current.getPcode();
                    if(operations==null || operations.length==0) throw new IllegalStateException("Empty instruction p-code");
                    boolean outside=!functionBodies.contains(current.getAddress(),current.getMaxAddress());
                    omission(omitted,cursor,address-1);
                    instruction(out,current,bytes,offset,operations,outside); buffer.send(target);
                    exported++; instructionBytes+=bytes.length; if(outside) outsideFunctions++;
                    previous=address; cursor=current.getMaxAddress().getOffset()+1; current=null;
                    if(exported%100000==0) { target.flush(); omitted.flush(); println("PCODE_STREAM_PROGRESS instructions="+exported+" expected="+expected); }
                }
                omission(omitted,cursor,text.getEnd().getOffset());
                complete=exported==expected && beforeHash.equals(hash(source));
                if(!complete) throw new IllegalStateException("Instruction count or original hash mismatch");
            } catch(Exception | AssertionError error) { failure=error; complete=false; buffer.clear(); out=json(buffer); }
            summary(out,complete,beforeHash,hash(source),expected,omissionsPath.getFileName().toString(),current,failure); buffer.send(target);
        }
        println("PCODE_STREAM_DONE complete="+complete+" instructions="+exported+" outside_functions="+outsideFunctions+" non_instruction_bytes="+omittedBytes);
        if(!complete) throw new IllegalStateException("Partial p-code stream retained",failure);
    }
}
