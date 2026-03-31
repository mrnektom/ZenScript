package org.zenscript.intellij

import com.intellij.extapi.psi.PsiFileBase
import com.intellij.openapi.fileTypes.FileType
import com.intellij.psi.FileViewProvider

class ZenScriptFile(viewProvider: FileViewProvider) : PsiFileBase(viewProvider, ZenScriptLanguage) {
    override fun getFileType(): FileType = ZenScriptFileType
    override fun toString(): String = "ZenScript File"
}
