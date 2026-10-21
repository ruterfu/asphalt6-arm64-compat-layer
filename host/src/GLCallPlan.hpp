#pragma once
#include <cstdint>
#include <cstring>
// Generated from the frozen import table; no runtime signature parsing.
namespace as6_render_plan {
enum class Call : std::uint16_t { Invalid=0,
    glActiveTexture=1,
    glAlphaFunc=2,
    glAttachShader=3,
    glBindBuffer=4,
    glBindFramebuffer=5,
    glBindFramebufferOES=6,
    glBindRenderbuffer=7,
    glBindRenderbufferOES=8,
    glBindTexture=9,
    glBlendColor=10,
    glBlendEquation=11,
    glBlendEquationOES=12,
    glBlendFunc=13,
    glBufferData=14,
    glBufferSubData=15,
    glCheckFramebufferStatus=16,
    glCheckFramebufferStatusOES=17,
    glClear=18,
    glClearColor=19,
    glClearDepthf=20,
    glClearStencil=21,
    glClientActiveTexture=22,
    glClipPlanef=23,
    glColor4f=24,
    glColor4ub=25,
    glColorMask=26,
    glColorPointer=27,
    glCompileShader=28,
    glCompressedTexImage2D=29,
    glCompressedTexSubImage2D=30,
    glCopyTexImage2D=31,
    glCopyTexSubImage2D=32,
    glCreateProgram=33,
    glCreateShader=34,
    glCullFace=35,
    glDeleteBuffers=36,
    glDeleteFramebuffers=37,
    glDeleteFramebuffersOES=38,
    glDeleteProgram=39,
    glDeleteRenderbuffers=40,
    glDeleteRenderbuffersOES=41,
    glDeleteShader=42,
    glDeleteTextures=43,
    glDepthFunc=44,
    glDepthMask=45,
    glDepthRangef=46,
    glDisable=47,
    glDisableClientState=48,
    glDisableVertexAttribArray=49,
    glDiscardFramebufferEXT=50,
    glDrawArrays=51,
    glDrawElements=52,
    glEnable=53,
    glEnableClientState=54,
    glEnableVertexAttribArray=55,
    glFlush=56,
    glFogf=57,
    glFogfv=58,
    glFramebufferRenderbuffer=59,
    glFramebufferRenderbufferOES=60,
    glFramebufferTexture2D=61,
    glFramebufferTexture2DOES=62,
    glFrontFace=63,
    glGenBuffers=64,
    glGenFramebuffers=65,
    glGenFramebuffersOES=66,
    glGenRenderbuffers=67,
    glGenRenderbuffersOES=68,
    glGenTextures=69,
    glGenerateMipmap=70,
    glGenerateMipmapOES=71,
    glGetActiveAttrib=72,
    glGetActiveUniform=73,
    glGetAttribLocation=74,
    glGetError=75,
    glGetFloatv=76,
    glGetIntegerv=77,
    glGetProgramInfoLog=78,
    glGetProgramiv=79,
    glGetRenderbufferParameterivOES=80,
    glGetShaderInfoLog=81,
    glGetShaderiv=82,
    glGetString=83,
    glGetStringi=84,
    glGetUniformLocation=85,
    glHint=86,
    glIsFramebuffer=87,
    glIsFramebufferOES=88,
    glIsRenderbuffer=89,
    glIsRenderbufferOES=90,
    glIsTexture=91,
    glLightModelf=92,
    glLightModelfv=93,
    glLightf=94,
    glLightfv=95,
    glLineWidth=96,
    glLinkProgram=97,
    glLoadIdentity=98,
    glLoadMatrixf=99,
    glMapBufferOES=100,
    glMaterialf=101,
    glMaterialfv=102,
    glMatrixMode=103,
    glMultMatrixf=104,
    glMultiTexCoord4f=105,
    glNormal3f=106,
    glNormalPointer=107,
    glPixelStorei=108,
    glPointParameterf=109,
    glPointParameterfv=110,
    glPointSize=111,
    glPolygonOffset=112,
    glPopMatrix=113,
    glPushMatrix=114,
    glReadPixels=115,
    glRenderbufferStorage=116,
    glRenderbufferStorageMultisampleAPPLE=117,
    glRenderbufferStorageOES=118,
    glResolveMultisampleFramebufferAPPLE=119,
    glSampleCoverage=120,
    glScissor=121,
    glShadeModel=122,
    glShaderSource=123,
    glStencilFunc=124,
    glStencilMask=125,
    glStencilOp=126,
    glTexCoordPointer=127,
    glTexEnvf=128,
    glTexEnvfv=129,
    glTexEnvi=130,
    glTexImage2D=131,
    glTexParameterf=132,
    glTexParameteri=133,
    glTexSubImage2D=134,
    glUniform1f=135,
    glUniform1fv=136,
    glUniform1i=137,
    glUniform1iv=138,
    glUniform2fv=139,
    glUniform2iv=140,
    glUniform3fv=141,
    glUniform3iv=142,
    glUniform4fv=143,
    glUniform4iv=144,
    glUniformMatrix4fv=145,
    glUnmapBufferOES=146,
    glUseProgram=147,
    glVertexAttrib4f=148,
    glVertexAttribPointer=149,
    glVertexPointer=150,
    glViewport=151,
};
struct Argument { char kind; std::int8_t source; std::uint16_t multiplier; };
struct Plan { const char *name,*signature; char result; std::uint8_t count; bool custom,mvp,observeResult,traceSurface; Argument arguments[12]; };
inline constexpr Plan Plans[]={ {nullptr,nullptr,0,0,false,false,false,false,{}},
    {"glActiveTexture","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glAlphaFunc","v:i,f",'v',2,false,false,false,false,{{'i',-1,0},{'f',-1,0}}},
    {"glAttachShader","v:i,i",'v',2,false,true,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBindBuffer","ov",'o',0,true,false,false,false,{}},
    {"glBindFramebuffer","v:i,i",'v',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBindFramebufferOES","i:i,i",'i',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBindRenderbuffer","v:i,i",'v',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBindRenderbufferOES","i:i,i",'i',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBindTexture","v:i,i",'v',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBlendColor","v:f,f,f,f",'v',4,false,false,false,false,{{'f',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glBlendEquation","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glBlendEquationOES","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glBlendFunc","v:i,i",'v',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glBufferData","v:i,i,M1:1,i",'v',4,true,false,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,1},{'i',-1,0}}},
    {"glBufferSubData","v:i,i,i,M2:1",'v',4,true,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'M',2,1}}},
    {"glCheckFramebufferStatus","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glCheckFramebufferStatusOES","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glClear","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glClearColor","v:f,f,f,f",'v',4,false,false,false,false,{{'f',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glClearDepthf","v:f",'v',1,false,false,false,false,{{'f',-1,0}}},
    {"glClearStencil","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glClientActiveTexture","v:i",'v',1,true,false,false,false,{{'i',-1,0}}},
    {"glClipPlanef","v:i,p16",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,16}}},
    {"glColor4f","v:f,f,f,f",'v',4,false,false,false,false,{{'f',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glColor4ub","v:i,i,i,i",'v',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glColorMask","v:i,i,i,i",'v',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glColorPointer","ov",'o',0,true,false,false,false,{}},
    {"glCompileShader","v:i",'v',1,false,true,false,false,{{'i',-1,0}}},
    {"glCompressedTexImage2D","v:i,i,i,i,i,i,i,M6:1",'v',8,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'M',6,1}}},
    {"glCompressedTexSubImage2D","v:i,i,i,i,i,i,i,i,M7:1",'v',9,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'M',7,1}}},
    {"glCopyTexImage2D","v:i,i,i,i,i,i,i,i",'v',8,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glCopyTexSubImage2D","v:i,i,i,i,i,i,i,i",'v',8,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glCreateProgram","i",'i',0,false,true,false,false,{}},
    {"glCreateShader","i:i",'i',1,false,true,false,false,{{'i',-1,0}}},
    {"glCullFace","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glDeleteBuffers","v:i,M0:4",'v',2,true,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDeleteFramebuffers","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDeleteFramebuffersOES","i:i,M0:4",'i',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDeleteProgram","v:i",'v',1,false,true,false,false,{{'i',-1,0}}},
    {"glDeleteRenderbuffers","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDeleteRenderbuffersOES","i:i,M0:4",'i',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDeleteShader","v:i",'v',1,false,true,false,false,{{'i',-1,0}}},
    {"glDeleteTextures","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glDepthFunc","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glDepthMask","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glDepthRangef","v:f,f",'v',2,false,false,false,false,{{'f',-1,0},{'f',-1,0}}},
    {"glDisable","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glDisableClientState","ov",'o',0,true,false,false,false,{}},
    {"glDisableVertexAttribArray","v:i",'v',1,true,false,false,false,{{'i',-1,0}}},
    {"glDiscardFramebufferEXT","i:i,i,M1:4",'i',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,4}}},
    {"glDrawArrays","ov",'o',0,true,false,false,false,{}},
    {"glDrawElements","ov",'o',0,true,false,false,false,{}},
    {"glEnable","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glEnableClientState","ov",'o',0,true,false,false,false,{}},
    {"glEnableVertexAttribArray","v:i",'v',1,true,false,false,false,{{'i',-1,0}}},
    {"glFlush","v",'v',0,false,false,false,false,{}},
    {"glFogf","v:i,f",'v',2,false,false,false,false,{{'i',-1,0},{'f',-1,0}}},
    {"glFogfv","v:i,p16",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,16}}},
    {"glFramebufferRenderbuffer","v:i,i,i,i",'v',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glFramebufferRenderbufferOES","i:i,i,i,i",'i',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glFramebufferTexture2D","v:i,i,i,i,i",'v',5,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glFramebufferTexture2DOES","i:i,i,i,i,i",'i',5,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glFrontFace","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glGenBuffers","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenFramebuffers","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenFramebuffersOES","i:i,M0:4",'i',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenRenderbuffers","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenRenderbuffersOES","i:i,M0:4",'i',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenTextures","v:i,M0:4",'v',2,false,false,false,false,{{'i',-1,0},{'M',0,4}}},
    {"glGenerateMipmap","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glGenerateMipmapOES","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glGetActiveAttrib","v:i,i,i,p4,p4,p4,M2:1",'v',7,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'p',-1,4},{'p',-1,4},{'p',-1,4},{'M',2,1}}},
    {"glGetActiveUniform","v:i,i,i,p4,p4,p4,M2:1",'v',7,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'p',-1,4},{'p',-1,4},{'p',-1,4},{'M',2,1}}},
    {"glGetAttribLocation","i:i,z",'i',2,false,false,false,false,{{'i',-1,0},{'z',-1,0}}},
    {"glGetError","i",'i',0,false,false,false,false,{}},
    {"glGetFloatv","v:i,p64",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,64}}},
    {"glGetIntegerv","v:i,p64",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,64}}},
    {"glGetProgramInfoLog","v:i,i,p4,M1:1",'v',4,false,false,true,false,{{'i',-1,0},{'i',-1,0},{'p',-1,4},{'M',1,1}}},
    {"glGetProgramiv","v:i,i,p16",'v',3,false,true,true,false,{{'i',-1,0},{'i',-1,0},{'p',-1,16}}},
    {"glGetRenderbufferParameterivOES","i:i,i,p16",'i',3,false,false,false,true,{{'i',-1,0},{'i',-1,0},{'p',-1,16}}},
    {"glGetShaderInfoLog","v:i,i,p4,M1:1",'v',4,false,false,true,false,{{'i',-1,0},{'i',-1,0},{'p',-1,4},{'M',1,1}}},
    {"glGetShaderiv","v:i,i,p16",'v',3,false,true,true,false,{{'i',-1,0},{'i',-1,0},{'p',-1,16}}},
    {"glGetString","ov",'o',0,true,false,false,false,{}},
    {"glGetStringi","ov",'o',0,true,false,false,false,{}},
    {"glGetUniformLocation","i:i,z",'i',2,false,true,false,false,{{'i',-1,0},{'z',-1,0}}},
    {"glHint","v:i,i",'v',2,false,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glIsFramebuffer","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glIsFramebufferOES","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glIsRenderbuffer","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glIsRenderbufferOES","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glIsTexture","i:i",'i',1,false,false,false,false,{{'i',-1,0}}},
    {"glLightModelf","v:i,f",'v',2,false,false,false,false,{{'i',-1,0},{'f',-1,0}}},
    {"glLightModelfv","v:i,p16",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,16}}},
    {"glLightf","v:i,i,f",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'f',-1,0}}},
    {"glLightfv","v:i,i,p64",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'p',-1,64}}},
    {"glLineWidth","v:f",'v',1,false,false,false,false,{{'f',-1,0}}},
    {"glLinkProgram","v:i",'v',1,false,true,false,false,{{'i',-1,0}}},
    {"glLoadIdentity","v",'v',0,false,false,false,false,{}},
    {"glLoadMatrixf","v:p64",'v',1,false,false,false,false,{{'p',-1,64}}},
    {"glMapBufferOES","ov",'o',0,true,false,false,false,{}},
    {"glMaterialf","v:i,i,f",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'f',-1,0}}},
    {"glMaterialfv","v:i,i,p64",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'p',-1,64}}},
    {"glMatrixMode","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glMultMatrixf","v:p64",'v',1,false,false,false,false,{{'p',-1,64}}},
    {"glMultiTexCoord4f","v:i,f,f,f,f",'v',5,false,false,false,false,{{'i',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glNormal3f","v:f,f,f",'v',3,false,false,false,false,{{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glNormalPointer","ov",'o',0,true,false,false,false,{}},
    {"glPixelStorei","v:i,i",'v',2,true,false,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glPointParameterf","v:i,f",'v',2,false,false,false,false,{{'i',-1,0},{'f',-1,0}}},
    {"glPointParameterfv","v:i,p16",'v',2,false,false,false,false,{{'i',-1,0},{'p',-1,16}}},
    {"glPointSize","v:f",'v',1,false,false,false,false,{{'f',-1,0}}},
    {"glPolygonOffset","v:f,f",'v',2,false,false,false,false,{{'f',-1,0},{'f',-1,0}}},
    {"glPopMatrix","v",'v',0,false,false,false,false,{}},
    {"glPushMatrix","v",'v',0,false,false,false,false,{}},
    {"glReadPixels","ov",'o',0,true,false,false,false,{}},
    {"glRenderbufferStorage","v:i,i,i,i",'v',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glRenderbufferStorageMultisampleAPPLE","i:i,i,i,i,i",'i',5,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glRenderbufferStorageOES","i:i,i,i,i",'i',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glResolveMultisampleFramebufferAPPLE","i",'i',0,false,false,false,false,{}},
    {"glSampleCoverage","v:f,i",'v',2,false,false,false,false,{{'f',-1,0},{'i',-1,0}}},
    {"glScissor","v:i,i,i,i",'v',4,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glShadeModel","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glShaderSource","ov",'o',0,true,false,false,false,{}},
    {"glStencilFunc","v:i,i,i",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glStencilMask","v:i",'v',1,false,false,false,false,{{'i',-1,0}}},
    {"glStencilOp","v:i,i,i",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glTexCoordPointer","ov",'o',0,true,false,false,false,{}},
    {"glTexEnvf","v:i,i,f",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'f',-1,0}}},
    {"glTexEnvfv","v:i,i,p16",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'p',-1,16}}},
    {"glTexEnvi","v:i,i,i",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glTexImage2D","ov",'o',0,true,false,false,false,{}},
    {"glTexParameterf","v:i,i,f",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'f',-1,0}}},
    {"glTexParameteri","v:i,i,i",'v',3,false,false,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
    {"glTexSubImage2D","ov",'o',0,true,false,false,false,{}},
    {"glUniform1f","v:i,f",'v',2,false,true,false,false,{{'i',-1,0},{'f',-1,0}}},
    {"glUniform1fv","v:i,i,M1:4",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,4}}},
    {"glUniform1i","v:i,i",'v',2,false,true,false,false,{{'i',-1,0},{'i',-1,0}}},
    {"glUniform1iv","v:i,i,M1:4",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,4}}},
    {"glUniform2fv","v:i,i,M1:8",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,8}}},
    {"glUniform2iv","v:i,i,M1:8",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,8}}},
    {"glUniform3fv","v:i,i,M1:12",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,12}}},
    {"glUniform3iv","v:i,i,M1:12",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,12}}},
    {"glUniform4fv","v:i,i,M1:16",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,16}}},
    {"glUniform4iv","v:i,i,M1:16",'v',3,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'M',1,16}}},
    {"glUniformMatrix4fv","v:i,i,i,M1:64",'v',4,false,true,false,false,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'M',1,64}}},
    {"glUnmapBufferOES","ov",'o',0,true,false,false,false,{}},
    {"glUseProgram","v:i",'v',1,false,true,false,false,{{'i',-1,0}}},
    {"glVertexAttrib4f","v:i,f,f,f,f",'v',5,false,false,false,false,{{'i',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0},{'f',-1,0}}},
    {"glVertexAttribPointer","ov",'o',0,true,false,false,false,{}},
    {"glVertexPointer","ov",'o',0,true,false,false,false,{}},
    {"glViewport","v:i,i,i,i",'v',4,false,false,false,true,{{'i',-1,0},{'i',-1,0},{'i',-1,0},{'i',-1,0}}},
};
inline constexpr unsigned Count=sizeof(Plans)/sizeof(Plans[0]);
inline const Plan *get(Call call) noexcept { const unsigned n=unsigned(call);return n&&n<Count?&Plans[n]:nullptr; }
// Dynamic callers retain exact string matching; registered imports use Call directly.
inline Call find(const char *name) noexcept { if(!name)return Call::Invalid;
    if(!std::strcmp(name,"glActiveTexture"))return Call::glActiveTexture;
    if(!std::strcmp(name,"glAlphaFunc"))return Call::glAlphaFunc;
    if(!std::strcmp(name,"glAttachShader"))return Call::glAttachShader;
    if(!std::strcmp(name,"glBindBuffer"))return Call::glBindBuffer;
    if(!std::strcmp(name,"glBindFramebuffer"))return Call::glBindFramebuffer;
    if(!std::strcmp(name,"glBindFramebufferOES"))return Call::glBindFramebufferOES;
    if(!std::strcmp(name,"glBindRenderbuffer"))return Call::glBindRenderbuffer;
    if(!std::strcmp(name,"glBindRenderbufferOES"))return Call::glBindRenderbufferOES;
    if(!std::strcmp(name,"glBindTexture"))return Call::glBindTexture;
    if(!std::strcmp(name,"glBlendColor"))return Call::glBlendColor;
    if(!std::strcmp(name,"glBlendEquation"))return Call::glBlendEquation;
    if(!std::strcmp(name,"glBlendEquationOES"))return Call::glBlendEquationOES;
    if(!std::strcmp(name,"glBlendFunc"))return Call::glBlendFunc;
    if(!std::strcmp(name,"glBufferData"))return Call::glBufferData;
    if(!std::strcmp(name,"glBufferSubData"))return Call::glBufferSubData;
    if(!std::strcmp(name,"glCheckFramebufferStatus"))return Call::glCheckFramebufferStatus;
    if(!std::strcmp(name,"glCheckFramebufferStatusOES"))return Call::glCheckFramebufferStatusOES;
    if(!std::strcmp(name,"glClear"))return Call::glClear;
    if(!std::strcmp(name,"glClearColor"))return Call::glClearColor;
    if(!std::strcmp(name,"glClearDepthf"))return Call::glClearDepthf;
    if(!std::strcmp(name,"glClearStencil"))return Call::glClearStencil;
    if(!std::strcmp(name,"glClientActiveTexture"))return Call::glClientActiveTexture;
    if(!std::strcmp(name,"glClipPlanef"))return Call::glClipPlanef;
    if(!std::strcmp(name,"glColor4f"))return Call::glColor4f;
    if(!std::strcmp(name,"glColor4ub"))return Call::glColor4ub;
    if(!std::strcmp(name,"glColorMask"))return Call::glColorMask;
    if(!std::strcmp(name,"glColorPointer"))return Call::glColorPointer;
    if(!std::strcmp(name,"glCompileShader"))return Call::glCompileShader;
    if(!std::strcmp(name,"glCompressedTexImage2D"))return Call::glCompressedTexImage2D;
    if(!std::strcmp(name,"glCompressedTexSubImage2D"))return Call::glCompressedTexSubImage2D;
    if(!std::strcmp(name,"glCopyTexImage2D"))return Call::glCopyTexImage2D;
    if(!std::strcmp(name,"glCopyTexSubImage2D"))return Call::glCopyTexSubImage2D;
    if(!std::strcmp(name,"glCreateProgram"))return Call::glCreateProgram;
    if(!std::strcmp(name,"glCreateShader"))return Call::glCreateShader;
    if(!std::strcmp(name,"glCullFace"))return Call::glCullFace;
    if(!std::strcmp(name,"glDeleteBuffers"))return Call::glDeleteBuffers;
    if(!std::strcmp(name,"glDeleteFramebuffers"))return Call::glDeleteFramebuffers;
    if(!std::strcmp(name,"glDeleteFramebuffersOES"))return Call::glDeleteFramebuffersOES;
    if(!std::strcmp(name,"glDeleteProgram"))return Call::glDeleteProgram;
    if(!std::strcmp(name,"glDeleteRenderbuffers"))return Call::glDeleteRenderbuffers;
    if(!std::strcmp(name,"glDeleteRenderbuffersOES"))return Call::glDeleteRenderbuffersOES;
    if(!std::strcmp(name,"glDeleteShader"))return Call::glDeleteShader;
    if(!std::strcmp(name,"glDeleteTextures"))return Call::glDeleteTextures;
    if(!std::strcmp(name,"glDepthFunc"))return Call::glDepthFunc;
    if(!std::strcmp(name,"glDepthMask"))return Call::glDepthMask;
    if(!std::strcmp(name,"glDepthRangef"))return Call::glDepthRangef;
    if(!std::strcmp(name,"glDisable"))return Call::glDisable;
    if(!std::strcmp(name,"glDisableClientState"))return Call::glDisableClientState;
    if(!std::strcmp(name,"glDisableVertexAttribArray"))return Call::glDisableVertexAttribArray;
    if(!std::strcmp(name,"glDiscardFramebufferEXT"))return Call::glDiscardFramebufferEXT;
    if(!std::strcmp(name,"glDrawArrays"))return Call::glDrawArrays;
    if(!std::strcmp(name,"glDrawElements"))return Call::glDrawElements;
    if(!std::strcmp(name,"glEnable"))return Call::glEnable;
    if(!std::strcmp(name,"glEnableClientState"))return Call::glEnableClientState;
    if(!std::strcmp(name,"glEnableVertexAttribArray"))return Call::glEnableVertexAttribArray;
    if(!std::strcmp(name,"glFlush"))return Call::glFlush;
    if(!std::strcmp(name,"glFogf"))return Call::glFogf;
    if(!std::strcmp(name,"glFogfv"))return Call::glFogfv;
    if(!std::strcmp(name,"glFramebufferRenderbuffer"))return Call::glFramebufferRenderbuffer;
    if(!std::strcmp(name,"glFramebufferRenderbufferOES"))return Call::glFramebufferRenderbufferOES;
    if(!std::strcmp(name,"glFramebufferTexture2D"))return Call::glFramebufferTexture2D;
    if(!std::strcmp(name,"glFramebufferTexture2DOES"))return Call::glFramebufferTexture2DOES;
    if(!std::strcmp(name,"glFrontFace"))return Call::glFrontFace;
    if(!std::strcmp(name,"glGenBuffers"))return Call::glGenBuffers;
    if(!std::strcmp(name,"glGenFramebuffers"))return Call::glGenFramebuffers;
    if(!std::strcmp(name,"glGenFramebuffersOES"))return Call::glGenFramebuffersOES;
    if(!std::strcmp(name,"glGenRenderbuffers"))return Call::glGenRenderbuffers;
    if(!std::strcmp(name,"glGenRenderbuffersOES"))return Call::glGenRenderbuffersOES;
    if(!std::strcmp(name,"glGenTextures"))return Call::glGenTextures;
    if(!std::strcmp(name,"glGenerateMipmap"))return Call::glGenerateMipmap;
    if(!std::strcmp(name,"glGenerateMipmapOES"))return Call::glGenerateMipmapOES;
    if(!std::strcmp(name,"glGetActiveAttrib"))return Call::glGetActiveAttrib;
    if(!std::strcmp(name,"glGetActiveUniform"))return Call::glGetActiveUniform;
    if(!std::strcmp(name,"glGetAttribLocation"))return Call::glGetAttribLocation;
    if(!std::strcmp(name,"glGetError"))return Call::glGetError;
    if(!std::strcmp(name,"glGetFloatv"))return Call::glGetFloatv;
    if(!std::strcmp(name,"glGetIntegerv"))return Call::glGetIntegerv;
    if(!std::strcmp(name,"glGetProgramInfoLog"))return Call::glGetProgramInfoLog;
    if(!std::strcmp(name,"glGetProgramiv"))return Call::glGetProgramiv;
    if(!std::strcmp(name,"glGetRenderbufferParameterivOES"))return Call::glGetRenderbufferParameterivOES;
    if(!std::strcmp(name,"glGetShaderInfoLog"))return Call::glGetShaderInfoLog;
    if(!std::strcmp(name,"glGetShaderiv"))return Call::glGetShaderiv;
    if(!std::strcmp(name,"glGetString"))return Call::glGetString;
    if(!std::strcmp(name,"glGetStringi"))return Call::glGetStringi;
    if(!std::strcmp(name,"glGetUniformLocation"))return Call::glGetUniformLocation;
    if(!std::strcmp(name,"glHint"))return Call::glHint;
    if(!std::strcmp(name,"glIsFramebuffer"))return Call::glIsFramebuffer;
    if(!std::strcmp(name,"glIsFramebufferOES"))return Call::glIsFramebufferOES;
    if(!std::strcmp(name,"glIsRenderbuffer"))return Call::glIsRenderbuffer;
    if(!std::strcmp(name,"glIsRenderbufferOES"))return Call::glIsRenderbufferOES;
    if(!std::strcmp(name,"glIsTexture"))return Call::glIsTexture;
    if(!std::strcmp(name,"glLightModelf"))return Call::glLightModelf;
    if(!std::strcmp(name,"glLightModelfv"))return Call::glLightModelfv;
    if(!std::strcmp(name,"glLightf"))return Call::glLightf;
    if(!std::strcmp(name,"glLightfv"))return Call::glLightfv;
    if(!std::strcmp(name,"glLineWidth"))return Call::glLineWidth;
    if(!std::strcmp(name,"glLinkProgram"))return Call::glLinkProgram;
    if(!std::strcmp(name,"glLoadIdentity"))return Call::glLoadIdentity;
    if(!std::strcmp(name,"glLoadMatrixf"))return Call::glLoadMatrixf;
    if(!std::strcmp(name,"glMapBufferOES"))return Call::glMapBufferOES;
    if(!std::strcmp(name,"glMaterialf"))return Call::glMaterialf;
    if(!std::strcmp(name,"glMaterialfv"))return Call::glMaterialfv;
    if(!std::strcmp(name,"glMatrixMode"))return Call::glMatrixMode;
    if(!std::strcmp(name,"glMultMatrixf"))return Call::glMultMatrixf;
    if(!std::strcmp(name,"glMultiTexCoord4f"))return Call::glMultiTexCoord4f;
    if(!std::strcmp(name,"glNormal3f"))return Call::glNormal3f;
    if(!std::strcmp(name,"glNormalPointer"))return Call::glNormalPointer;
    if(!std::strcmp(name,"glPixelStorei"))return Call::glPixelStorei;
    if(!std::strcmp(name,"glPointParameterf"))return Call::glPointParameterf;
    if(!std::strcmp(name,"glPointParameterfv"))return Call::glPointParameterfv;
    if(!std::strcmp(name,"glPointSize"))return Call::glPointSize;
    if(!std::strcmp(name,"glPolygonOffset"))return Call::glPolygonOffset;
    if(!std::strcmp(name,"glPopMatrix"))return Call::glPopMatrix;
    if(!std::strcmp(name,"glPushMatrix"))return Call::glPushMatrix;
    if(!std::strcmp(name,"glReadPixels"))return Call::glReadPixels;
    if(!std::strcmp(name,"glRenderbufferStorage"))return Call::glRenderbufferStorage;
    if(!std::strcmp(name,"glRenderbufferStorageMultisampleAPPLE"))return Call::glRenderbufferStorageMultisampleAPPLE;
    if(!std::strcmp(name,"glRenderbufferStorageOES"))return Call::glRenderbufferStorageOES;
    if(!std::strcmp(name,"glResolveMultisampleFramebufferAPPLE"))return Call::glResolveMultisampleFramebufferAPPLE;
    if(!std::strcmp(name,"glSampleCoverage"))return Call::glSampleCoverage;
    if(!std::strcmp(name,"glScissor"))return Call::glScissor;
    if(!std::strcmp(name,"glShadeModel"))return Call::glShadeModel;
    if(!std::strcmp(name,"glShaderSource"))return Call::glShaderSource;
    if(!std::strcmp(name,"glStencilFunc"))return Call::glStencilFunc;
    if(!std::strcmp(name,"glStencilMask"))return Call::glStencilMask;
    if(!std::strcmp(name,"glStencilOp"))return Call::glStencilOp;
    if(!std::strcmp(name,"glTexCoordPointer"))return Call::glTexCoordPointer;
    if(!std::strcmp(name,"glTexEnvf"))return Call::glTexEnvf;
    if(!std::strcmp(name,"glTexEnvfv"))return Call::glTexEnvfv;
    if(!std::strcmp(name,"glTexEnvi"))return Call::glTexEnvi;
    if(!std::strcmp(name,"glTexImage2D"))return Call::glTexImage2D;
    if(!std::strcmp(name,"glTexParameterf"))return Call::glTexParameterf;
    if(!std::strcmp(name,"glTexParameteri"))return Call::glTexParameteri;
    if(!std::strcmp(name,"glTexSubImage2D"))return Call::glTexSubImage2D;
    if(!std::strcmp(name,"glUniform1f"))return Call::glUniform1f;
    if(!std::strcmp(name,"glUniform1fv"))return Call::glUniform1fv;
    if(!std::strcmp(name,"glUniform1i"))return Call::glUniform1i;
    if(!std::strcmp(name,"glUniform1iv"))return Call::glUniform1iv;
    if(!std::strcmp(name,"glUniform2fv"))return Call::glUniform2fv;
    if(!std::strcmp(name,"glUniform2iv"))return Call::glUniform2iv;
    if(!std::strcmp(name,"glUniform3fv"))return Call::glUniform3fv;
    if(!std::strcmp(name,"glUniform3iv"))return Call::glUniform3iv;
    if(!std::strcmp(name,"glUniform4fv"))return Call::glUniform4fv;
    if(!std::strcmp(name,"glUniform4iv"))return Call::glUniform4iv;
    if(!std::strcmp(name,"glUniformMatrix4fv"))return Call::glUniformMatrix4fv;
    if(!std::strcmp(name,"glUnmapBufferOES"))return Call::glUnmapBufferOES;
    if(!std::strcmp(name,"glUseProgram"))return Call::glUseProgram;
    if(!std::strcmp(name,"glVertexAttrib4f"))return Call::glVertexAttrib4f;
    if(!std::strcmp(name,"glVertexAttribPointer"))return Call::glVertexAttribPointer;
    if(!std::strcmp(name,"glVertexPointer"))return Call::glVertexPointer;
    if(!std::strcmp(name,"glViewport"))return Call::glViewport;
    return Call::Invalid;
}
} // namespace as6_render_plan
