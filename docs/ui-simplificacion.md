# Simplificación de la interfaz

Criterio para que Shepherdr enseñe lo mínimo a primera vista y el detalle al entrar. Sigue las Leyes de la Simplicidad de John Maeda.

## Principios

1. **Reducir.** Cada elemento visible tiene que ayudar a decidir o a actuar ahora. Lo que solo informa (rutas, IDs, intervalos, pistas de atajos) va a un tooltip, al panel de detalles o a la guía.
2. **Organizar.** Cada función tiene un único sitio visible. Los menús de la barra de menús y los atajos de teclado son el segundo camino de siempre en macOS y no cuentan como duplicado.
3. **Ahorrar tiempo.** Lo frecuente queda a un clic (crear sesión, abrir una sesión, enviar un prompt, bloquear). Lo raro pasa a menús contextuales o al menú "⋯".
4. **Diferencias.** El color se reserva para el estado: ámbar si una sesión te necesita, rojo si algo falla. El resto va en tonos neutros.
5. **Contexto.** El estado de la conexión y de la tapa del Mac solo aparece cuando hay algo que hacer: una máquina caída, el refresco en pausa o agentes que se pararían al cerrar la tapa.
6. **Confianza.** No se pierde nada. Todo lo que sale de la vista sigue en el panel de detalles, en un menú o en un tooltip.
7. **Lenguaje.** Los textos visibles hablan de sesiones, máquinas y carpetas. Nada de pane, workspace, terminal ID ni comandos. Los términos de Herdr solo aparecen en los detalles.
8. **Estética.** Iconos SF Symbols sobrios en lugar de etiquetas de texto en los botones de herramientas, espacio generoso y una sola línea por sesión. Se mantienen la paleta y la tipografía de la app.

## Ubicación canónica

| Función | Dónde | Segundo camino |
|---|---|---|
| Crear una sesión | "+" en la cabecera de la barra lateral | ⌘N, menú File |
| Ver el estado de todas las sesiones | Icono de estado en cada fila de la barra lateral; recuentos en Overview | Badge de la pestaña AGENTS |
| Ver el detalle de una sesión | Botón ⓘ de la cabecera de la sesión: máquina, carpeta, agente, comandos que siguen en marcha, ID de pane | — |
| Actuar sobre una sesión (renombrar, cerrar, esperar, prioridad, grupo, copiar referencia) | Menú contextual de la fila | Menú Session |
| Pull requests de una sesión | Panel Resources de la sesión; "Open Pull Requests" en el menú contextual de la fila; ✗ en la fila solo si fallan los checks | — |
| Herramientas de la sesión abierta (editor de prompt, dictado, teclas, recursos, navegador, bloqueo) | Iconos a la derecha de la cabecera de la sesión | ⌘L, ⇧⌘M, ⌘B, ⌘E, ⌘⎋ |
| Organizar la cola (grupos, agrupar por proyecto) | Menú "⋯" de la cabecera "Sessions" | Menú View y menú Session |
| Máquinas: estado | Tarjetas de máquina en Overview; aviso en el pie de la barra lateral solo si alguna falla | — |
| Máquinas: gestión | Settings → Machines | — |
| Ajustes | ⚙ en el pie de la barra lateral | ⌘, |
| Mantener el Mac despierto | Taza en el pie de la barra lateral | — |
| Ayuda | Menú Help → Shepherdr Guide | ⌘? |
| Actualizaciones | Aviso al pie de la barra lateral cuando hay una versión nueva | Menú de la app |

## Qué cambió

- **Barra lateral.** Cada fila muestra el icono de estado y el nombre, más la máquina (si hay varias) y el sobre de correo cuando hay correo. El título, el agente, la carpeta, los PR y los comandos en marcha pasan al tooltip y a la vista de la sesión. Se quitaron el número de prioridad (el orden ya lo da la posición y ⌘1…⌘9 sigue funcionando) y el resumen de la cabecera. "[ ] projects" y "+ group" pasan al menú "⋯". El pie se reduce a un aviso de estado, que solo aparece cuando hace falta, la taza y ⚙.
- **Barra inferior de la sesión.** Desaparece. Sus controles pasan a iconos en la cabecera. Las seis teclas rápidas se agrupan en un menú de teclado y la línea de pistas se elimina (está en la guía).
- **Cabecera de la sesión.** Muestra el estado, el nombre y el título. La línea de ubicación, el ID de pane, el agente y los comandos en marcha pasan al panel ⓘ.
