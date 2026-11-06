import {encodeAbiParameters,type Hex} from 'viem';
const label=/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
export function canonicalName(value:string):string{
 const name=value.trim().toLowerCase();
 const labels=name.split('.');
 if(labels.some(part=>!label.test(part)))throw new Error('Use lowercase ASCII letters, numbers and internal hyphens. Unicode names are not supported yet.');
 if(1+labels.reduce((sum,part)=>sum+part.length+1,0)>255)throw new Error('This name is too long.');
 return name;
}
export function parentLabels(value:string):string[]{
 const labels=canonicalName(value).split('.');
 if(labels.length<2||labels.length>8||labels.at(-1)!=='eth')throw new Error('Choose a supported ENSv2 parent ending in .eth.');
 return labels.reverse();
}
export function ensEvidence(name:string,parent:string):Hex{
 const full=canonicalName(name),domain=canonicalName(parent);
 if(!full.endsWith('.'+domain))throw new Error('Enter a subname beneath '+domain+'.');
 const children=full.slice(0,-domain.length-1).split('.');
 if(children.length<1||children.length>8)throw new Error('Use a subname up to eight levels below the parent.');
 return encodeAbiParameters([{type:'string[]'}],[children.reverse()]);
}
export const ensReasons=[
 'Name ownership confirmed.','Connect a wallet.','The name evidence is invalid.','The registry is on a different network.',
 'The trusted registry changed.','This label is unsupported.','The name has too many levels.','This name is too long.',
 'The parent name is inactive or expired.','This parent has no child registry.','This registry type is unsupported.',
 'The name is inactive or expired.','This wallet does not currently own the name.',
];
