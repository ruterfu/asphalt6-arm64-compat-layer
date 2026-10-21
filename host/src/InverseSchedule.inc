// Fixed owned numerical schedule, derived from pinned original bytes.
// 0x1b2020: vldr s10, [sp, #0xc4]
pair[5].low=input.matrix[11];
// 0x1b2024: vldr s14, [sp, #0xb0]
pair[7].low=input.matrix[6];
// 0x1b2028: vmul.f32 d9, d5, d7
pair[9]=fp.multiply(pair[5],pair[7]);
// 0x1b202c: vldr s8, [sp, #0xd4]
pair[4].low=input.matrix[15];
// 0x1b2030: vldr s20, [sp, #0xb4]
pair[10].low=input.matrix[7];
// 0x1b2034: vldr s6, [sp, #0xc0]
pair[3].low=input.matrix[10];
// 0x1b2038: vldr s2, [sp, #0xa0]
pair[1].low=input.matrix[2];
// 0x1b203c: vstr s6, [sp, #8]
store<8,4,0x1b203cu>(pair[3].low,scratch,fp,result);
// 0x1b2040: vmul.f32 d0, d3, d4
pair[0]=fp.multiply(pair[3],pair[4]);
// 0x1b2044: vmul.f32 d8, d4, d7
pair[8]=fp.multiply(pair[4],pair[7]);
// 0x1b2048: vmls.f32 s18, s6, s20
pair[9].low=fp.subtractProduct(pair[9].low,pair[3].low,pair[10].low);
// 0x1b204c: vstr s2, [sp, #0x14]
store<20,4,0x1b204cu>(pair[1].low,scratch,fp,result);
// 0x1b2050: vldr s6, [sp, #0xa4]
pair[3].low=input.matrix[3];
// 0x1b2054: vstr s6, [sp, #0x44]
store<68,4,0x1b2054u>(pair[3].low,scratch,fp,result);
// 0x1b2058: vmul.f32 d3, d4, d1
pair[3]=fp.multiply(pair[4],pair[1]);
// 0x1b205c: vmul.f32 d1, d5, d1
pair[1]=fp.multiply(pair[5],pair[1]);
// 0x1b2060: vldr s12, [sp, #0xd0]
pair[6].low=input.matrix[14];
// 0x1b2064: vldr s28, [sp, #0xcc]
pair[14].low=input.matrix[13];
// 0x1b2068: vldr s24, [sp, #0xbc]
pair[12].low=input.matrix[9];
// 0x1b206c: vldr s26, [sp, #0xa8]
pair[13].low=input.matrix[4];
// 0x1b2070: vstr s8, [sp, #0x50]
store<80,4,0x1b2070u>(pair[4].low,scratch,fp,result);
// 0x1b2074: vstr s10, [sp, #0x4c]
store<76,4,0x1b2074u>(pair[5].low,scratch,fp,result);
// 0x1b2078: vldr s8, [sp, #0x44]
pair[4].low=scratch[17];
// 0x1b207c: vstr s12, [sp, #0x18]
store<24,4,0x1b207cu>(pair[6].low,scratch,fp,result);
// 0x1b2080: vldr s30, [sp, #0xc8]
pair[15].low=input.matrix[12];
// 0x1b2084: vstr s14, [sp, #0x10]
store<16,4,0x1b2084u>(pair[7].low,scratch,fp,result);
// 0x1b2088: vldr s22, [sp, #0x98]
pair[11].low=input.matrix[0];
// 0x1b208c: vstr s20, [sp, #0x48]
store<72,4,0x1b208cu>(pair[10].low,scratch,fp,result);
// 0x1b2090: strb r3, [sp, #0x94]
store<148,1,0x1b2090u>(input.gpr[3],scratch,fp,result);
// 0x1b2094: vmls.f32 s0, s10, s12
pair[0].low=fp.subtractProduct(pair[0].low,pair[5].low,pair[6].low);
// 0x1b2098: vldr s10, [sp, #8]
pair[5].low=scratch[2];
// 0x1b209c: vmls.f32 s16, s12, s20
pair[8].low=fp.subtractProduct(pair[8].low,pair[6].low,pair[10].low);
// 0x1b20a0: vmls.f32 s6, s12, s8
pair[3].low=fp.subtractProduct(pair[3].low,pair[6].low,pair[4].low);
// 0x1b20a4: vldr s12, [sp, #0x14]
pair[6].low=scratch[5];
// 0x1b20a8: vmul.f32 d2, d10, d6
pair[2]=fp.multiply(pair[10],pair[6]);
// 0x1b20ac: vmul.f32 d6, d12, d13
pair[6]=fp.multiply(pair[12],pair[13]);
// 0x1b20b0: vmls.f32 s2, s10, s8
pair[1].low=fp.subtractProduct(pair[1].low,pair[5].low,pair[4].low);
// 0x1b20b4: vmul.f32 d5, d14, d13
pair[5]=fp.multiply(pair[14],pair[13]);
// 0x1b20b8: vmls.f32 s4, s14, s8
pair[2].low=fp.subtractProduct(pair[2].low,pair[7].low,pair[4].low);
// 0x1b20bc: vldr s14, [sp, #0xb8]
pair[7].low=input.matrix[8];
// 0x1b20c0: vldr s8, [sp, #0xac]
pair[4].low=input.matrix[5];
// 0x1b20c4: vstr s14, [sp, #0xc]
store<12,4,0x1b20c4u>(pair[7].low,scratch,fp,result);
// 0x1b20c8: vmul.f32 d10, d7, d14
pair[10]=fp.multiply(pair[7],pair[14]);
// 0x1b20cc: vmls.f32 s12, s14, s8
pair[6].low=fp.subtractProduct(pair[6].low,pair[7].low,pair[4].low);
// 0x1b20d0: vmul.f32 d7, d12, d11
pair[7]=fp.multiply(pair[12],pair[11]);
// 0x1b20d4: vmls.f32 s10, s30, s8
pair[5].low=fp.subtractProduct(pair[5].low,pair[15].low,pair[4].low);
// 0x1b20d8: vstr s12, [sp, #0x38]
store<56,4,0x1b20d8u>(pair[6].low,scratch,fp,result);
// 0x1b20dc: vldr s12, [sp, #0xc]
pair[6].low=scratch[3];
// 0x1b20e0: vmls.f32 s20, s24, s30
pair[10].low=fp.subtractProduct(pair[10].low,pair[12].low,pair[15].low);
// 0x1b20e4: vstr s10, [sp, #0x3c]
store<60,4,0x1b20e4u>(pair[5].low,scratch,fp,result);
// 0x1b20e8: vldr s10, [sp, #0x9c]
pair[5].low=input.matrix[1];
// 0x1b20ec: vmls.f32 s14, s12, s10
pair[7].low=fp.subtractProduct(pair[7].low,pair[6].low,pair[5].low);
// 0x1b20f0: vstr s20, [sp, #0x40]
store<64,4,0x1b20f0u>(pair[10].low,scratch,fp,result);
// 0x1b20f4: vmul.f32 d10, d14, d11
pair[10]=fp.multiply(pair[14],pair[11]);
// 0x1b20f8: vstr s14, [sp, #0x34]
store<52,4,0x1b20f8u>(pair[7].low,scratch,fp,result);
// 0x1b20fc: vmul.f32 d7, d4, d11
pair[7]=fp.multiply(pair[4],pair[11]);
// 0x1b2100: vmls.f32 s20, s30, s10
pair[10].low=fp.subtractProduct(pair[10].low,pair[15].low,pair[5].low);
// 0x1b2104: vldr s12, [sp, #0x34]
pair[6].low=scratch[13];
// 0x1b2108: vmls.f32 s14, s26, s10
pair[7].low=fp.subtractProduct(pair[7].low,pair[13].low,pair[5].low);
// 0x1b210c: vstr s14, [sp, #0x30]
store<48,4,0x1b210cu>(pair[7].low,scratch,fp,result);
// 0x1b2110: vmul.f32 d7, d0, d7
pair[7]=fp.multiply(pair[0],pair[7]);
// 0x1b2114: vmls.f32 s14, s16, s12
pair[7].low=fp.subtractProduct(pair[7].low,pair[8].low,pair[6].low);
// 0x1b2118: vmul.f32 d6, d9, d10
pair[6]=fp.multiply(pair[9],pair[10]);
// 0x1b211c: vadd.f32 d7, d7, d6
pair[7]=fp.add(pair[7],pair[6]);
// 0x1b2120: vldr s12, [sp, #0x38]
pair[6].low=scratch[14];
// 0x1b2124: vstr s14, [sp, #4]
store<4,4,0x1b2124u>(pair[7].low,scratch,fp,result);
// 0x1b2128: vmul.f32 d7, d3, d6
pair[7]=fp.multiply(pair[3],pair[6]);
// 0x1b212c: vldr s12, [sp, #4]
pair[6].low=scratch[1];
// 0x1b2130: vadd.f32 d7, d6, d7
pair[7]=fp.add(pair[6],pair[7]);
// 0x1b2134: vldr s12, [sp, #0x3c]
pair[6].low=scratch[15];
// 0x1b2138: vmls.f32 s14, s2, s12
pair[7].low=fp.subtractProduct(pair[7].low,pair[1].low,pair[6].low);
// 0x1b213c: vldr s12, [sp, #0x40]
pair[6].low=scratch[16];
// 0x1b2140: vstr s14, [sp]
store<0,4,0x1b2140u>(pair[7].low,scratch,fp,result);
// 0x1b2144: vmul.f32 d7, d2, d6
pair[7]=fp.multiply(pair[2],pair[6]);
// 0x1b2148: vldr s12, [sp]
pair[6].low=scratch[0];
// 0x1b214c: vadd.f32 d7, d6, d7
pair[7]=fp.add(pair[6],pair[7]);
// 0x1b2150: vstr s14, [sp, #0x2c]
store<44,4,0x1b2150u>(pair[7].low,scratch,fp,result);
// 0x1b2154: vabs.f32 s14, s14
pair[7].low=fp.absolute(pair[7].low);
// 0x1b2158: vldr s12, [pc, #0x290]
pair[6].low=EpsilonBits;
// 0x1b215c: vcmpe.f32 s14, s12
fp.compare(pair[7].low,pair[6].low);
// 0x1b2160: vmrs apsr_nzcv, fpscr
result.apsrNzcv=fp.fpscr&0xf0000000u;
// 0x1b2164: bls #0x1b1e38
if(!(fp.fpscr&(1u<<29))||(fp.fpscr&(1u<<30)))return finish(SmallExit,82);
// 0x1b2168: vmul.f32 d7, d0, d4
pair[7]=fp.multiply(pair[0],pair[4]);
// 0x1b216c: vmul.f32 d6, d9, d14
pair[6]=fp.multiply(pair[9],pair[14]);
// 0x1b2170: vmls.f32 s14, s16, s24
pair[7].low=fp.subtractProduct(pair[7].low,pair[8].low,pair[12].low);
// 0x1b2174: add r0, sp, #0x98
result.gpr[0]=input.stackAddress+152u;
// 0x1b2178: add r1, sp, #0x54
result.gpr[1]=input.stackAddress+84u;
// 0x1b217c: mov r2, #0x41
result.gpr[2]=65;
// 0x1b2180: vadd.f32 d7, d7, d6
pair[7]=fp.add(pair[7],pair[6]);
// 0x1b2184: vstr s14, [sp, #0x28]
store<40,4,0x1b2184u>(pair[7].low,scratch,fp,result);
// 0x1b2188: vmul.f32 d7, d3, d12
pair[7]=fp.multiply(pair[3],pair[12]);
// 0x1b218c: vmul.f32 d6, d2, d14
pair[6]=fp.multiply(pair[2],pair[14]);
// 0x1b2190: vmls.f32 s14, s0, s10
pair[7].low=fp.subtractProduct(pair[7].low,pair[0].low,pair[5].low);
// 0x1b2194: vmls.f32 s14, s2, s28
pair[7].low=fp.subtractProduct(pair[7].low,pair[1].low,pair[14].low);
// 0x1b2198: vmul.f32 d14, d1, d4
pair[14]=fp.multiply(pair[1],pair[4]);
// 0x1b219c: vstr s14, [sp, #0x24]
store<36,4,0x1b219cu>(pair[7].low,scratch,fp,result);
// 0x1b21a0: vmul.f32 d7, d8, d5
pair[7]=fp.multiply(pair[8],pair[5]);
// 0x1b21a4: vmls.f32 s28, s18, s10
pair[14].low=fp.subtractProduct(pair[14].low,pair[9].low,pair[5].low);
// 0x1b21a8: vldr s10, [sp, #0x40]
pair[5].low=scratch[16];
// 0x1b21ac: vmls.f32 s14, s6, s8
pair[7].low=fp.subtractProduct(pair[7].low,pair[3].low,pair[4].low);
// 0x1b21b0: vldr s8, [sp, #0xc]
pair[4].low=scratch[3];
// 0x1b21b4: vadd.f32 d7, d7, d6
pair[7]=fp.add(pair[7],pair[6]);
// 0x1b21b8: vstr s14, [sp, #0x20]
store<32,4,0x1b21b8u>(pair[7].low,scratch,fp,result);
// 0x1b21bc: vmul.f32 d7, d0, d11
pair[7]=fp.multiply(pair[0],pair[11]);
// 0x1b21c0: vmul.f32 d6, d1, d15
pair[6]=fp.multiply(pair[1],pair[15]);
// 0x1b21c4: vmls.f32 s14, s6, s8
pair[7].low=fp.subtractProduct(pair[7].low,pair[3].low,pair[4].low);
// 0x1b21c8: vadd.f32 d7, d7, d6
pair[7]=fp.add(pair[7],pair[6]);
// 0x1b21cc: vstr s14, [sp, #0x1c]
store<28,4,0x1b21ccu>(pair[7].low,scratch,fp,result);
// 0x1b21d0: vmul.f32 d7, d9, d11
pair[7]=fp.multiply(pair[9],pair[11]);
// 0x1b21d4: vmls.f32 s28, s4, s24
pair[14].low=fp.subtractProduct(pair[14].low,pair[2].low,pair[12].low);
// 0x1b21d8: vmul.f32 d12, d8, d4
pair[12]=fp.multiply(pair[8],pair[4]);
// 0x1b21dc: vmul.f32 d6, d2, d4
pair[6]=fp.multiply(pair[2],pair[4]);
// 0x1b21e0: vldr s8, [sp, #0x38]
pair[4].low=scratch[14];
// 0x1b21e4: vmls.f32 s14, s2, s26
pair[7].low=fp.subtractProduct(pair[7].low,pair[1].low,pair[13].low);
// 0x1b21e8: vldr s2, [sp, #0x3c]
pair[1].low=scratch[15];
// 0x1b21ec: vmls.f32 s24, s0, s26
pair[12].low=fp.subtractProduct(pair[12].low,pair[0].low,pair[13].low);
// 0x1b21f0: vmul.f32 d0, d3, d13
pair[0]=fp.multiply(pair[3],pair[13]);
// 0x1b21f4: vadd.f32 d13, d7, d6
pair[13]=fp.add(pair[7],pair[6]);
// 0x1b21f8: vldr s12, [sp, #0x48]
pair[6].low=scratch[18];
// 0x1b21fc: vmul.f32 d7, d5, d6
pair[7]=fp.multiply(pair[5],pair[6]);
// 0x1b2200: vldr s6, [sp, #0x4c]
pair[3].low=scratch[19];
// 0x1b2204: vldr s10, [sp, #0x50]
pair[5].low=scratch[20];
// 0x1b2208: vmul.f32 d6, d4, d5
pair[6]=fp.multiply(pair[4],pair[5]);
// 0x1b220c: vldr s8, [sp, #0x48]
pair[4].low=scratch[18];
// 0x1b2210: vmls.f32 s0, s16, s22
pair[0].low=fp.subtractProduct(pair[0].low,pair[8].low,pair[11].low);
// 0x1b2214: vmls.f32 s14, s2, s6
pair[7].low=fp.subtractProduct(pair[7].low,pair[1].low,pair[3].low);
// 0x1b2218: vldr s2, [sp, #0x34]
pair[1].low=scratch[13];
// 0x1b221c: vmls.f32 s0, s4, s30
pair[0].low=fp.subtractProduct(pair[0].low,pair[2].low,pair[15].low);
// 0x1b2220: vmul.f32 d2, d10, d3
pair[2]=fp.multiply(pair[10],pair[3]);
// 0x1b2224: vadd.f32 d11, d7, d6
pair[11]=fp.add(pair[7],pair[6]);
// 0x1b2228: vldr s6, [sp, #0x3c]
pair[3].low=scratch[15];
// 0x1b222c: vldr s12, [sp, #0x40]
pair[6].low=scratch[16];
// 0x1b2230: vldr s14, [sp, #0x44]
pair[7].low=scratch[17];
// 0x1b2234: vmls.f32 s4, s12, s14
pair[2].low=fp.subtractProduct(pair[2].low,pair[6].low,pair[7].low);
// 0x1b2238: vmul.f32 d7, d3, d7
pair[7]=fp.multiply(pair[3],pair[7]);
// 0x1b223c: vmls.f32 s14, s20, s8
pair[7].low=fp.subtractProduct(pair[7].low,pair[10].low,pair[4].low);
// 0x1b2240: vmls.f32 s4, s2, s10
pair[2].low=fp.subtractProduct(pair[2].low,pair[1].low,pair[5].low);
// 0x1b2244: vldr s2, [sp, #0x30]
pair[1].low=scratch[12];
// 0x1b2248: vmul.f32 d6, d1, d5
pair[6]=fp.multiply(pair[1],pair[5]);
// 0x1b224c: vldr s10, [sp, #0x34]
pair[5].low=scratch[13];
// 0x1b2250: vmul.f32 d3, d5, d4
pair[3]=fp.multiply(pair[5],pair[4]);
// 0x1b2254: vldr s8, [sp, #0x4c]
pair[4].low=scratch[19];
// 0x1b2258: vldr s10, [sp, #0x3c]
pair[5].low=scratch[15];
// 0x1b225c: vmls.f32 s24, s18, s30
pair[12].low=fp.subtractProduct(pair[12].low,pair[9].low,pair[15].low);
// 0x1b2260: vadd.f32 d9, d7, d6
pair[9]=fp.add(pair[7],pair[6]);
// 0x1b2264: vldr s12, [sp, #0x38]
pair[6].low=scratch[14];
// 0x1b2268: vldr s14, [sp, #0x44]
pair[7].low=scratch[17];
// 0x1b226c: vmls.f32 s6, s12, s14
pair[3].low=fp.subtractProduct(pair[3].low,pair[6].low,pair[7].low);
// 0x1b2270: vldr s12, [sp, #8]
pair[6].low=scratch[2];
// 0x1b2274: vldr s14, [sp, #0x40]
pair[7].low=scratch[16];
// 0x1b2278: vmls.f32 s6, s2, s8
pair[3].low=fp.subtractProduct(pair[3].low,pair[1].low,pair[4].low);
// 0x1b227c: vmul.f32 d4, d5, d6
pair[4]=fp.multiply(pair[5],pair[6]);
// 0x1b2280: vldr s2, [sp, #0x10]
pair[1].low=scratch[4];
// 0x1b2284: vldr s10, [sp, #0x38]
pair[5].low=scratch[14];
// 0x1b2288: vldr s12, [sp, #0x18]
pair[6].low=scratch[6];
// 0x1b228c: vmls.f32 s8, s14, s2
pair[4].low=fp.subtractProduct(pair[4].low,pair[7].low,pair[1].low);
// 0x1b2290: vldr s2, [sp, #0x14]
pair[1].low=scratch[5];
// 0x1b2294: vmul.f32 d7, d7, d1
pair[7]=fp.multiply(pair[7],pair[1]);
// 0x1b2298: vldr s2, [sp, #0x34]
pair[1].low=scratch[13];
// 0x1b229c: vmls.f32 s8, s10, s12
pair[4].low=fp.subtractProduct(pair[4].low,pair[5].low,pair[6].low);
// 0x1b22a0: vldr s10, [sp, #8]
pair[5].low=scratch[2];
// 0x1b22a4: vmul.f32 d6, d1, d6
pair[6]=fp.multiply(pair[1],pair[6]);
// 0x1b22a8: vldr s2, [sp, #0x30]
pair[1].low=scratch[12];
// 0x1b22ac: vmls.f32 s14, s20, s10
pair[7].low=fp.subtractProduct(pair[7].low,pair[10].low,pair[5].low);
// 0x1b22b0: vadd.f32 d8, d7, d6
pair[8]=fp.add(pair[7],pair[6]);
// 0x1b22b4: vldr s12, [sp, #0x10]
pair[6].low=scratch[4];
// 0x1b22b8: vmul.f32 d5, d10, d6
pair[5]=fp.multiply(pair[10],pair[6]);
// 0x1b22bc: vldr s14, [sp, #0x3c]
pair[7].low=scratch[15];
// 0x1b22c0: vldr s20, [sp, #0x14]
pair[10].low=scratch[5];
// 0x1b22c4: vmls.f32 s10, s14, s20
pair[5].low=fp.subtractProduct(pair[5].low,pair[7].low,pair[10].low);
// 0x1b22c8: vldr s12, [sp, #0x18]
pair[6].low=scratch[6];
// 0x1b22cc: vmls.f32 s10, s2, s12
pair[5].low=fp.subtractProduct(pair[5].low,pair[1].low,pair[6].low);
// 0x1b22d0: vldr s2, [sp, #0x38]
pair[1].low=scratch[14];
// 0x1b22d4: vmul.f32 d7, d1, d10
pair[7]=fp.multiply(pair[1],pair[10]);
// 0x1b22d8: vldr s12, [sp, #0x34]
pair[6].low=scratch[13];
// 0x1b22dc: vldr s20, [sp, #0x10]
pair[10].low=scratch[4];
// 0x1b22e0: vldr s2, [sp, #0x30]
pair[1].low=scratch[12];
// 0x1b22e4: vmls.f32 s14, s12, s20
pair[7].low=fp.subtractProduct(pair[7].low,pair[6].low,pair[10].low);
// 0x1b22e8: vldr s20, [sp, #8]
pair[10].low=scratch[2];
// 0x1b22ec: vmul.f32 d6, d1, d10
pair[6]=fp.multiply(pair[1],pair[10]);
// 0x1b22f0: vldr s20, [sp, #0x28]
pair[10].low=scratch[10];
// 0x1b22f4: vadd.f32 d1, d7, d6
pair[1]=fp.add(pair[7],pair[6]);
// 0x1b22f8: vmov.f32 s14, #1.000000e+00
pair[7].low=0x3f800000u;
// 0x1b22fc: vldr s12, [sp, #0x2c]
pair[6].low=scratch[11];
// 0x1b2300: vdiv.f32 s14, s14, s12
pair[7].low=fp.divide(pair[7].low,pair[6].low);
// 0x1b2304: vmul.f32 d6, d10, d7
pair[6]=fp.multiply(pair[10],pair[7]);
// 0x1b2308: vstr s12, [sp, #0x54]
store<84,4,0x1b2308u>(pair[6].low,scratch,fp,result);
// 0x1b230c: vldr s20, [sp, #0x24]
pair[10].low=scratch[9];
// 0x1b2310: vmul.f32 d6, d10, d7
pair[6]=fp.multiply(pair[10],pair[7]);
// 0x1b2314: vldr s20, [sp, #0x20]
pair[10].low=scratch[8];
// 0x1b2318: vstr s12, [sp, #0x58]
store<88,4,0x1b2318u>(pair[6].low,scratch,fp,result);
// 0x1b231c: vmul.f32 d6, d10, d7
pair[6]=fp.multiply(pair[10],pair[7]);
// 0x1b2320: vldr s20, [sp, #0x1c]
pair[10].low=scratch[7];
// 0x1b2324: vstr s12, [sp, #0x5c]
store<92,4,0x1b2324u>(pair[6].low,scratch,fp,result);
// 0x1b2328: vmul.f32 d6, d14, d7
pair[6]=fp.multiply(pair[14],pair[7]);
// 0x1b232c: vstr s12, [sp, #0x60]
store<96,4,0x1b232cu>(pair[6].low,scratch,fp,result);
// 0x1b2330: vmul.f32 d6, d12, d7
pair[6]=fp.multiply(pair[12],pair[7]);
// 0x1b2334: vstr s12, [sp, #0x64]
store<100,4,0x1b2334u>(pair[6].low,scratch,fp,result);
// 0x1b2338: vmul.f32 d6, d10, d7
pair[6]=fp.multiply(pair[10],pair[7]);
// 0x1b233c: vstr s12, [sp, #0x68]
store<104,4,0x1b233cu>(pair[6].low,scratch,fp,result);
// 0x1b2340: vmul.f32 d6, d0, d7
pair[6]=fp.multiply(pair[0],pair[7]);
// 0x1b2344: vstr s12, [sp, #0x6c]
store<108,4,0x1b2344u>(pair[6].low,scratch,fp,result);
// 0x1b2348: vmul.f32 d6, d13, d7
pair[6]=fp.multiply(pair[13],pair[7]);
// 0x1b234c: vstr s12, [sp, #0x70]
store<112,4,0x1b234cu>(pair[6].low,scratch,fp,result);
// 0x1b2350: vmul.f32 d6, d11, d7
pair[6]=fp.multiply(pair[11],pair[7]);
// 0x1b2354: vstr s12, [sp, #0x74]
store<116,4,0x1b2354u>(pair[6].low,scratch,fp,result);
// 0x1b2358: vmul.f32 d6, d2, d7
pair[6]=fp.multiply(pair[2],pair[7]);
// 0x1b235c: vstr s12, [sp, #0x78]
store<120,4,0x1b235cu>(pair[6].low,scratch,fp,result);
// 0x1b2360: vmul.f32 d6, d9, d7
pair[6]=fp.multiply(pair[9],pair[7]);
// 0x1b2364: vstr s12, [sp, #0x7c]
store<124,4,0x1b2364u>(pair[6].low,scratch,fp,result);
// 0x1b2368: vmul.f32 d6, d3, d7
pair[6]=fp.multiply(pair[3],pair[7]);
// 0x1b236c: vstr s12, [sp, #0x80]
store<128,4,0x1b236cu>(pair[6].low,scratch,fp,result);
// 0x1b2370: vmul.f32 d6, d4, d7
pair[6]=fp.multiply(pair[4],pair[7]);
// 0x1b2374: vstr s12, [sp, #0x84]
store<132,4,0x1b2374u>(pair[6].low,scratch,fp,result);
// 0x1b2378: vmul.f32 d6, d8, d7
pair[6]=fp.multiply(pair[8],pair[7]);
// 0x1b237c: vstr s12, [sp, #0x88]
store<136,4,0x1b237cu>(pair[6].low,scratch,fp,result);
// 0x1b2380: vmul.f32 d6, d5, d7
pair[6]=fp.multiply(pair[5],pair[7]);
// 0x1b2384: vmul.f32 d7, d1, d7
pair[7]=fp.multiply(pair[1],pair[7]);
// 0x1b2388: vstr s12, [sp, #0x8c]
store<140,4,0x1b2388u>(pair[6].low,scratch,fp,result);
// 0x1b238c: vstr s14, [sp, #0x90]
store<144,4,0x1b238cu>(pair[7].low,scratch,fp,result);
