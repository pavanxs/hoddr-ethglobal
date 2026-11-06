import {formatUnits} from 'viem';
import {toUnits} from '../ui/draft';
export const Q96=1n<<96n;
export const WAD=10n**18n;
export const UINT128_MAX=(1n<<128n)-1n;
export const MAX_AUCTION_SUPPLY=1n<<100n;
export function decimal(value:string,label='Amount',allowZero=false):bigint{
 const result=toUnits(value);
 if(result===null)throw new Error(label+' must be a plain number with up to 18 decimal places.');
 if((!allowZero&&result===0n)||result>UINT128_MAX)throw new Error(label+' is out of range.');
 return result;
}
export const amount=(value:bigint)=>formatUnits(value,18);
export function priceToQ96(value:string,round:'up'|'down'='down'):bigint{
 const numerator=decimal(value,'Price')*Q96;
 return round==='up'?(numerator+WAD-1n)/WAD:numerator/WAD;
}
export function priceFromQ96(value:bigint):string{return amount(value*WAD/Q96);}
export function floorPrice(value:string):bigint{
 const price=priceToQ96(value,'up');
 return price+(price%2n);
}
export function bidPrice(value:string,spacing:bigint):bigint{
 if(spacing<2n)throw new Error('Invalid auction price spacing.');
 const price=priceToQ96(value);
 return price-price%spacing;
}
export function safeNumber(value:bigint|number,label:string):number{
 const number=Number(value);if(!Number.isSafeInteger(number)||number<0)throw new Error(label+' is outside the supported range.');return number;
}
export function positiveInteger(value:number,label:string,max:number):number{
 if(!Number.isSafeInteger(value)||value<1||value>max)throw new Error(label+' is out of range.');return value;
}
