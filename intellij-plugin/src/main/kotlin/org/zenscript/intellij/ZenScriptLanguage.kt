package org.zenscript.intellij

import com.intellij.lang.Language

object ZenScriptLanguage : Language("ZenScript") {
    private fun readResolve(): Any = ZenScriptLanguage
}
