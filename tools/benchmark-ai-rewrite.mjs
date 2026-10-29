// Synthetic notes only. Never reads application data or user credentials.
import { getRewriteConfig, getAiRewriteStatus, rewriteNote } from '../server/ai/rewrite.mjs';
const texts = ["Mme Test a 82 ans. Elle rencontre des dificultés pour rentré dans sa douche. Les marches sont trop haute. Elle ne peut pas monter les escaliers sans aide. Le seuil mesure 2,5 cm. Les bénéficiaires souhaitent conservé leur autonomie. Il faut installé une barre de maintient.","Mme Test a 82 ans et vit seul dans une maison à étage. Elle dit que pour allé dans la salle de bain c'est compliqué parce que le passage est étroit et avec son déambulateur elle arrive pas à tourné. Elle ne peut pas monter les escaliers sans aide. Le seuil de douche fait 2,5 cm. Le sol est glissant quand il est mouillé. Elle souhaite gardé son autonomie et continué à utilisé sa salle de bain. La fille vient deux fois par semaine mais ne peut pas être présente tout les jours. Il y a une barre déjà installé mais elle est trop loin pour être attrapé quand elle rentre dans la douche. Un siège de douche est envisagé, sous réserve de vérifié que la place est suffisante. Il faut également évalué le positionnement de la barre de maintien. Mme Test ne souhaite pas remplacé la baignoire pour le moment."];
const config = getRewriteConfig();
const status = await getAiRewriteStatus({ config });
if (!status.ready) throw new Error('Configurer OPENROUTER_API_KEY avant la mesure.');
const results = [];
for (let pass = 0; pass < 3; pass++) {
  for (const text of texts) {
    const start = performance.now();
    const result = await rewriteNote({ text, config });
    results.push({ pass, sourceChars: text.length, elapsedMs: Math.round(performance.now() - start), ...result });
  }
}
console.log(JSON.stringify({
  provider: config.provider,
  model: config.model,
  maxMs: Math.max(...results.map((row) => row.elapsedMs)),
  allUnderFiveSeconds: results.every((row) => row.elapsedMs < 5000),
  results,
}, null, 2));
