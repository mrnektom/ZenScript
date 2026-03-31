package org.zenscript.intellij.psi

import com.intellij.psi.tree.IElementType
import org.zenscript.intellij.ZenScriptLanguage

class ZenScriptTokenType(debugName: String) : IElementType(debugName, ZenScriptLanguage) {
    override fun toString(): String = "ZenScriptTokenType.${super.toString()}"
}
